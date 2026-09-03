require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

class ValidateWorkflowPreflightTest < Minitest::Test
  def workflow
    @workflow ||= YAML.safe_load(File.read(".github/workflows/validate.yml"), aliases: false)
  end

  def validate_job
    workflow.fetch("jobs").fetch("validate")
  end

  def run_with_skipped_repository_create(step_run, interpolation: {})
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)

      octostate = File.join(bin, "octostate")
      File.write(octostate, <<~'SH')
        #!/bin/sh
        set -eu
        printf '%s\n' '{"status":"check","data":{"skipped_actions":[{"resource_type":"repository","operation":"create","resource_id":"orang-gaboets-test/new-repository","executable":false}]}}'
      SH
      FileUtils.chmod(0o755, octostate)

      git = File.join(bin, "git")
      File.write(git, <<~'SH')
        #!/bin/sh
        set -eu
        case "$*" in
          "fetch origin main --depth=1") exit 0 ;;
          "rev-parse origin/main") printf '%s\n' "$VALIDATED_SHA" ;;
          *) printf '%s\n' "unexpected git call: $*" >&2; exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, git)

      script = interpolation.reduce(step_run.dup) { |body, (needle, replacement)| body.gsub(needle, replacement) }
      env = {
        "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
        "GITHUB_STEP_SUMMARY" => File.join(dir, "summary"),
        "OCTOSTATE_APPLY_TOKEN" => "token",
        "VALIDATED_SHA" => "validated-sha"
      }
      Open3.capture3(env, "bash", "-euo", "pipefail", "-c", script)
    end
  end

  def test_validates_issue_template_yaml
    workflow_run = validate_job.fetch("steps").find { |step| step["name"] == "Validate workflow YAML" }.fetch("run")
    assert_includes workflow_run, ".github/{workflows,ISSUE_TEMPLATE}/*.{yml,yaml}"

    Dir[".github/ISSUE_TEMPLATE/*.{yml,yaml}"].sort.each do |file|
      YAML.safe_load(File.read(file), aliases: false)
    end
  end

  def test_documents_least_privilege_preflight_app_permissions
    readme = File.read("README.md")

    assert_includes readme, "read access to organization members and repository metadata"
    refute_includes readme, "read access to pull requests, organization members, and repository metadata"
  end

  def test_publishes_octostate_preflight_status
    refute workflow.fetch("permissions").key?("statuses")

    steps = validate_job.fetch("steps")
    checkout = steps.find { |step| step["name"] == "Checkout" }
    workflow_yaml = steps.find { |step| step["name"] == "Validate workflow YAML" }
    regression = steps.find { |step| step["name"] == "Run workflow regression tests" }
    setup_go = steps.find { |step| step["name"] == "Set up Go" }
    install = steps.find { |step| step["name"] == "Install octostate" }
    validate_config = steps.find { |step| step["name"] == "Validate config" }
    issue_tests = steps.find { |step| step["name"] == "Run issue-to-config tests" }
    status_token = steps.find { |step| step["name"] == "Create preflight status GitHub App token" }
    apply_token = steps.find { |step| step["name"] == "Create preflight read GitHub App token" }
    skip = steps.find { |step| step["name"] == "Skip Octostate preflight for non-organization PRs" }
    pending = steps.find { |step| step["name"] == "Mark preflight status pending" }
    provenance = steps.find { |step| step["name"] == "Check organization-change provenance" }
    preflight = steps.find { |step| step["name"] == "Preflight apply" }
    publish = steps.find { |step| step["name"] == "Publish preflight status" }

    refute_nil checkout
    refute_nil workflow_yaml
    refute_nil regression
    refute_nil setup_go
    refute_nil install
    refute_nil validate_config
    refute_nil issue_tests
    refute_nil status_token
    refute_nil apply_token
    assert_nil skip
    refute_nil pending
    refute_nil provenance
    refute_nil preflight
    refute_nil publish

    assert_nil checkout["if"]
    assert_includes workflow_yaml.fetch("if"), "github.event_name == 'pull_request' && steps.detect.outputs.workflow_changed == 'true'"
    assert_includes workflow_yaml.fetch("run"), '*.{yml,yaml}'
    assert_includes regression.fetch("run"), 'Dir["./test/*_test.rb"]'
    assert_equal "github.event_name != 'pull_request_target'", setup_go.fetch("if")
    assert_equal "github.event_name != 'pull_request'", install.fetch("if")
    assert_equal "github.event_name != 'pull_request'", validate_config.fetch("if")
    assert_equal "tools/issue-to-config", issue_tests.fetch("working-directory")
    assert_includes issue_tests.fetch("run"), "go test ./..."
    assert_includes workflow_yaml.fetch("run"), "YAML.safe_load(File.read"
    refute_includes workflow_yaml.fetch("run"), "YAML.load_file"
    assert_equal "${{ github.event.repository.name }}", status_token.fetch("with").fetch("repositories")
    assert_equal "write", status_token.fetch("with").fetch("permission-statuses")
    refute status_token.fetch("with").key?("permission-pull-requests")
    assert_equal "read", apply_token.fetch("with").fetch("permission-members")
    assert_equal "read", apply_token.fetch("with").fetch("permission-metadata")
    refute apply_token.fetch("with").key?("permission-statuses")
    assert_equal "${{ github.event_name == 'pull_request_target' && steps.detect.outputs.merge_sha || github.sha }}", checkout.fetch("with").fetch("ref")
    assert_operator steps.index(status_token), :<, steps.index(pending)
    assert_operator steps.index(pending), :<, steps.index(provenance)
    assert_operator steps.index(status_token), :<, steps.index(publish)
    assert_equal "${{ steps.preflight-status-app-token.outputs.token }}", pending.fetch("env").fetch("GH_TOKEN")
    assert_equal "${{ steps.preflight-status-app-token.outputs.token }}", publish.fetch("env").fetch("GH_TOKEN")
    assert_equal "${{ steps.detect.outputs.head_sha }}", pending.fetch("env").fetch("PRECHECK_SHA")
    assert_includes preflight.fetch("run"), '--token "${{ steps.preflight-read-app-token.outputs.token }}"'
    assert_equal "github.event_name == 'pull_request_target'", preflight.fetch("if")
    assert_operator steps.index(apply_token), :<, steps.index(preflight)
    assert_includes pending.fetch("run"), "Octostate preflight"
    assert_equal "${{ steps.detect.outputs.head_sha }}", publish.fetch("env").fetch("PRECHECK_SHA")
    assert_equal "${{ job.status }}", publish.fetch("env").fetch("JOB_STATUS")
    assert_includes publish.fetch("run"), "No organization config change detected."
    assert_includes publish.fetch("run"), 'if [ "$JOB_STATUS" = "success" ]'
    refute_includes publish.fetch("run"), 'if [ "$CONFIG_CHANGED" != "true" ]'
    assert_includes publish.fetch("run"), "Octostate preflight"
    assert_includes publish.fetch("if"), "always()"
  end

  def test_preflight_rejects_skipped_repository_create
    preflight = validate_job.fetch("steps").find { |step| step["name"] == "Preflight apply" }
    stdout, stderr, status = run_with_skipped_repository_create(
      preflight.fetch("run"),
      interpolation: { '${{ steps.preflight-read-app-token.outputs.token }}' => "token" }
    )

    refute status.success?, "preflight unexpectedly succeeded: #{stdout}#{stderr}"
    assert_includes stdout, "skipped repository creation"
  end

  def test_live_apply_rejects_skipped_repository_create
    apply_workflow = YAML.safe_load(File.read(".github/workflows/apply.yml"), aliases: false)
    apply = apply_workflow.fetch("jobs").fetch("apply").fetch("steps").find { |step| step["name"] == "Apply config if validated commit is still current" }
    stdout, stderr, status = run_with_skipped_repository_create(apply.fetch("run"))

    refute status.success?, "live apply unexpectedly succeeded: #{stdout}#{stderr}"
    assert_includes stdout, "skipped repository creation"
  end
end
