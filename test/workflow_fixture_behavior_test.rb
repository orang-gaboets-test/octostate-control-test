require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

class WorkflowFixtureBehaviorTest < Minitest::Test
  def validate_workflow
    @validate_workflow ||= YAML.safe_load(File.read(".github/workflows/validate.yml"), aliases: false)
  end

  def apply_workflow
    @apply_workflow ||= YAML.safe_load(File.read(".github/workflows/apply.yml"), aliases: false)
  end

  def detect_step
    @detect_step ||= validate_workflow.fetch("jobs").fetch("validate").fetch("steps").find { |step| step["name"] == "Detect config change" }
  end

  def detect_script
    detect_step.fetch("run").sub('${{ github.event_name }}', 'pull_request_target')
  end

  def provenance_step
    @provenance_step ||= apply_workflow.fetch("jobs").fetch("apply").fetch("steps").find { |step| step["name"] == "Verify apply provenance" }
  end

  def stale_step
    @stale_step ||= apply_workflow.fetch("jobs").fetch("apply").fetch("steps").find { |step| step["name"] == "Check for newer main commit after apply" }
  end

  def jq(expression, input, slurp: true, **args)
    command = ["jq"]
    command << "-s" if slurp
    args.each do |key, value|
      command.concat(["--arg", key.to_s, value])
    end
    command << expression
    stdout, stderr, status = Open3.capture3(*command, stdin_data: input.to_json)
    assert status.success?, "jq failed: #{stderr}"
    stdout.strip
  end

  def run_detect_script(merge_config_state: :missing, changed_files: 1, files_json: '[{"filename":"docs/README.md"}]')
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)

      gh = File.join(bin, "gh")
      File.write(gh, <<~'SH')
        #!/bin/sh
        set -eu
        case "$2" in
          "repos/orang-gaboets-test/octostate-control-test/pulls/42")
            case "${4:-}" in
              ".changed_files")
                printf '%s\n' "$CHANGED_FILES"
                ;;
              *)
                printf '%s\n' '{"base":{"sha":"base-sha"},"head":{"sha":"head-sha"},"merge_commit_sha":"current-merge-sha"}'
                ;;
            esac
            ;;
          "repos/orang-gaboets-test/octostate-control-test/contents/config/organization.yaml?ref=base-sha")
            printf '%s\n' '{"sha":"base-config-sha"}'
            ;;
          "repos/orang-gaboets-test/octostate-control-test/contents/config/organization.yaml?ref=current-merge-sha")
            case "$MERGE_CONFIG_STATE" in
              same) printf '%s\n' '{"sha":"base-config-sha"}' ;;
              different) printf '%s\n' '{"sha":"current-merge-config-sha"}' ;;
              *) printf '%s\n' 'Not Found' >&2; exit 1 ;;
            esac
            ;;
          "repos/orang-gaboets-test/octostate-control-test/contents/config/organization.yaml?ref=old-merge-sha")
            printf '%s\n' '{"sha":"base-config-sha"}'
            ;;
          "repos/orang-gaboets-test/octostate-control-test/pulls/42/files")
            printf '%s\n' "$FILES_JSON"
            ;;
          *)
            printf '%s\n' "unexpected gh call: $*" >&2
            exit 1
            ;;
        esac
      SH
      FileUtils.chmod(0o755, gh)

      output = File.join(dir, "output")
      env = {
        "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
        "GITHUB_OUTPUT" => output,
        "GITHUB_REPOSITORY" => "orang-gaboets-test/octostate-control-test",
        "GITHUB_EVENT_NAME" => "pull_request_target",
        "PR_NUMBER" => "42",
        "REPOSITORY" => "orang-gaboets-test/octostate-control-test",
        "BASE_SHA" => "old-base-sha",
        "MERGE_SHA" => "old-merge-sha",
        "GH_TOKEN" => "token",
        "MERGE_CONFIG_STATE" => merge_config_state.to_s,
        "CHANGED_FILES" => changed_files.to_s,
        "FILES_JSON" => files_json
      }

      _stdout, stderr, status = Open3.capture3(env, "bash", "-euo", "pipefail", "-c", detect_script)
      output_contents = File.exist?(output) ? File.read(output) : ""
      [stderr, status, output_contents]
    end
  end

  def run_provenance_script(parent_config_exists: true)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)

      gh = File.join(bin, "gh")
      File.write(gh, <<~'SH')
        #!/bin/sh
        set -eu
        jq_expr="${4:-}"
        case "$2" in
          "repos/orang-gaboets-test/octostate-control-test/commits/validated-sha")
            case "$jq_expr" in
              ".parents[0].sha // empty") printf '%s\n' 'parent-sha' ;;
              *) printf '%s\n' '{"parents":[{"sha":"parent-sha"}]}' ;;
            esac
            ;;
          "repos/orang-gaboets-test/octostate-control-test/contents/config/organization.yaml?ref=validated-sha")
            case "$jq_expr" in
              ".sha") printf '%s\n' 'validated-config-sha' ;;
              *) printf '%s\n' '{"sha":"validated-config-sha"}' ;;
            esac
            ;;
          "repos/orang-gaboets-test/octostate-control-test/contents/config/organization.yaml?ref=parent-sha")
            if [ "$PARENT_CONFIG_EXISTS" = "true" ]; then
              case "$jq_expr" in
                ".sha") printf '%s\n' 'parent-config-sha' ;;
                *) printf '%s\n' '{"sha":"parent-config-sha"}' ;;
              esac
            else
              printf '%s\n' 'Not Found' >&2
              exit 1
            fi
            ;;
          "repos/orang-gaboets-test/octostate-control-test/commits?sha=validated-sha&path=config/organization.yaml&per_page=1")
            case "$jq_expr" in
              ".[0].sha // empty") printf '%s\n' 'introducing-sha' ;;
              *) printf '%s\n' '[{"sha":"introducing-sha"}]' ;;
            esac
            ;;
          "repos/orang-gaboets-test/octostate-control-test/commits/introducing-sha/pulls")
            printf '%s\n' '[{"merged_at":"2026-07-26T00:00:00Z","head":{"repo":{"full_name":"orang-gaboets-test/octostate-control-test"},"ref":"automation/repository-request-1"},"base":{"repo":{"full_name":"orang-gaboets-test/octostate-control-test"},"ref":"main"},"user":{"login":"octostate-pr[bot]"}}]'
            ;;
          *)
            printf '%s\n' "unexpected gh call: $*" >&2
            exit 1
            ;;
        esac
      SH
      FileUtils.chmod(0o755, gh)

      output = File.join(dir, "output")
      env = {
        "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
        "GITHUB_OUTPUT" => output,
        "GH_TOKEN" => "token",
        "REPOSITORY" => "orang-gaboets-test/octostate-control-test",
        "VALIDATED_SHA" => "validated-sha",
        "OCTOSTATE_PR_APP_LOGIN" => "octostate-pr[bot]",
        "PARENT_CONFIG_EXISTS" => parent_config_exists ? "true" : "false"
      }

      _stdout, stderr, status = Open3.capture3(env, "bash", "-euo", "pipefail", "-c", provenance_step.fetch("run"))
      output_contents = File.exist?(output) ? File.read(output) : ""
      [stderr, status, output_contents]
    end
  end

  def test_detect_config_change_mentions_blob_lookup_and_workflow_detection
    run = detect_step.fetch("run")
    assert_includes run, 'gh api "repos/$REPOSITORY/pulls/$PR_NUMBER"'
    assert_includes run, "jq -r '.base.sha'"
    assert_includes run, "head_sha"
    assert_includes run, "jq -r '.merge_commit_sha // .head.sha'"
    assert_includes run, "merge_sha"
    assert_includes run, 'contents/config/organization.yaml?ref=$base_sha'
    assert_includes run, 'contents/config/organization.yaml?ref=$merge_sha'
    assert_includes run, "config_changed=false"
    refute_includes run, "treating it as a config-changing PR"
    assert_includes run, 'startswith(".github/workflows/")'

    workflow_expr = 'add | any((.filename | startswith(".github/workflows/")) or ((.previous_filename // "") | startswith(".github/workflows/")))'

    assert_equal "true", jq(workflow_expr, [
      { "filename" => ".github/workflows/renamed.yml", "previous_filename" => ".github/workflows/validate.yml" }
    ])
  end

  def test_detect_config_change_treats_missing_config_as_changed
    stderr, status, output = run_detect_script
    assert status.success?, "detect script failed: #{stderr}"
    assert_includes output, "config_changed=true"
  end

  def test_detect_config_change_marks_truncated_pr_file_lists_for_workflow_validation
    stderr, status, output = run_detect_script(
      merge_config_state: :same,
      changed_files: 2,
      files_json: '[{"filename":"docs/README.md"}]'
    )

    assert status.success?, "detect script failed: #{stderr}"
    assert_includes output, "workflow_changed=true"
  end

  def test_detect_config_change_uses_live_pr_revision
    stderr, status, output = run_detect_script(merge_config_state: :different)

    assert status.success?, "detect script failed: #{stderr}"
    assert_includes output, "config_changed=true"
    assert_includes output, "head_sha=head-sha"
    assert_includes output, "merge_sha=current-merge-sha"
  end

  def test_apply_provenance_filter_counts_only_authorized_same_repo_prs
    run = provenance_step.fetch("run")
    assert_includes run, 'select(.base.ref == "main")'
    assert_includes run, 'select(.head.ref | startswith("automation/repository-request-"))'

    repository = "orang-gaboets-test/octostate-control-test"
    app_login = "octostate-pr[bot]"
    prs = [
      {
        "merged_at" => "2026-07-26T00:00:00Z",
        "head" => { "repo" => { "full_name" => repository }, "ref" => "automation/repository-request-12" },
        "base" => { "repo" => { "full_name" => repository }, "ref" => "main" },
        "user" => { "login" => app_login }
      },
      {
        "merged_at" => nil,
        "head" => { "repo" => { "full_name" => repository }, "ref" => "automation/repository-request-13" },
        "base" => { "repo" => { "full_name" => repository }, "ref" => "main" },
        "user" => { "login" => app_login }
      },
      {
        "merged_at" => "2026-07-26T00:00:00Z",
        "head" => { "repo" => { "full_name" => "someone/fork" }, "ref" => "automation/repository-request-14" },
        "base" => { "repo" => { "full_name" => repository }, "ref" => "main" },
        "user" => { "login" => app_login }
      },
      {
        "merged_at" => "2026-07-26T00:00:00Z",
        "head" => { "repo" => { "full_name" => repository }, "ref" => "feature/other" },
        "base" => { "repo" => { "full_name" => repository }, "ref" => "main" },
        "user" => { "login" => app_login }
      },
      {
        "merged_at" => "2026-07-26T00:00:00Z",
        "head" => { "repo" => { "full_name" => repository }, "ref" => "automation/repository-request-15" },
        "base" => { "repo" => { "full_name" => repository }, "ref" => "develop" },
        "user" => { "login" => app_login }
      },
      {
        "merged_at" => "2026-07-26T00:00:00Z",
        "head" => { "repo" => { "full_name" => repository }, "ref" => "automation/repository-request-16" },
        "base" => { "repo" => { "full_name" => repository }, "ref" => "main" },
        "user" => { "login" => "alice" }
      }
    ]

    filter = '[ .[]? | select(.merged_at != null) | select(.head.repo.full_name == $repository) | select(.base.repo.full_name == $repository) | select(.base.ref == "main") | select(.user.login == $app_login) | select(.head.ref | startswith("automation/repository-request-")) ] | length'
    assert_equal "1", jq(filter, prs, slurp: false, repository: repository, app_login: app_login)
  end

  def test_apply_provenance_step_treats_missing_parent_config_as_changed
    stderr, status, output = run_provenance_script(parent_config_exists: false)

    assert status.success?, "provenance step failed: #{stderr}"
    assert_includes output, "apply_required=true"
  end

  def test_apply_stale_revision_step_documents_reconciliation
    run = stale_step.fetch("run")
    assert_includes run, "validated_config_blob"
    assert_includes run, "latest_main_config_blob"
    assert_includes run, "A newer validation/apply cycle must reconcile the current state."
  end
end
