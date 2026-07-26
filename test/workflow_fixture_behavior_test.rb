require "json"
require "minitest/autorun"
require "open3"
require "yaml"

class WorkflowFixtureBehaviorTest < Minitest::Test
  def validate_workflow
    @validate_workflow ||= YAML.load_file(".github/workflows/validate.yml")
  end

  def apply_workflow
    @apply_workflow ||= YAML.load_file(".github/workflows/apply.yml")
  end

  def detect_step
    @detect_step ||= validate_workflow.fetch("jobs").fetch("validate").fetch("steps").find { |step| step["name"] == "Detect config change" }
  end

  def provenance_step
    @provenance_step ||= apply_workflow.fetch("jobs").fetch("apply").fetch("steps").find { |step| step["name"] == "Verify apply provenance" }
  end

  def stale_step
    @stale_step ||= apply_workflow.fetch("jobs").fetch("apply").fetch("steps").find { |step| step["name"] == "Check for newer main commit after apply" }
  end

  def jq(expression, input, args = {}, slurp: true)
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

  def test_detect_config_change_uses_rename_and_truncation_fixtures
    run = detect_step.fetch("run")
    assert_includes run, "GitHub truncated the PR file list"
    assert_includes run, '(.previous_filename // "") == "config/organization.yaml"'
    assert_includes run, 'startswith(".github/workflows/")'

    config_expr = 'add | any(.filename == "config/organization.yaml" or (.previous_filename // "") == "config/organization.yaml")'
    workflow_expr = 'add | any((.filename | startswith(".github/workflows/")) or ((.previous_filename // "") | startswith(".github/workflows/")))'

    assert_equal "true", jq(config_expr, [
      { "filename" => "docs/README.md" },
      { "filename" => "config/new-name.yaml", "previous_filename" => "config/organization.yaml" }
    ])
    assert_equal "false", jq(config_expr, [
      { "filename" => "docs/README.md" }
    ])
    assert_equal "true", jq(workflow_expr, [
      { "filename" => ".github/workflows/renamed.yml", "previous_filename" => ".github/workflows/validate.yml" }
    ])
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
    assert_equal "1", jq(filter, prs, "repository" => repository, "app_login" => app_login, slurp: false)
  end

  def test_apply_stale_revision_step_documents_reconciliation
    run = stale_step.fetch("run")
    assert_includes run, "validated_config_blob"
    assert_includes run, "latest_main_config_blob"
    assert_includes run, "A newer validation/apply cycle must reconcile the current state."
  end
end
