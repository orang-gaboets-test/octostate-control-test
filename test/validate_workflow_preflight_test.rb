require "minitest/autorun"
require "yaml"

class ValidateWorkflowPreflightTest < Minitest::Test
  def workflow
    @workflow ||= YAML.safe_load(File.read(".github/workflows/validate.yml"), aliases: false)
  end

  def validate_job
    workflow.fetch("jobs").fetch("validate")
  end

  def test_publishes_octostate_preflight_status
    refute workflow.fetch("permissions").key?("statuses")

    steps = validate_job.fetch("steps")
    checkout = steps.find { |step| step["name"] == "Checkout" }
    workflow_yaml = steps.find { |step| step["name"] == "Validate workflow YAML" }
    regression = steps.find { |step| step["name"] == "Run workflow regression tests" }
    setup_go = steps.find { |step| step["name"] == "Set up Go" }
    issue_tests = steps.find { |step| step["name"] == "Run issue-to-config tests" }
    status_token = steps.find { |step| step["name"] == "Create preflight status GitHub App token" }
    apply_token = steps.find { |step| step["name"] == "Create preflight read GitHub App token" }
    skip = steps.find { |step| step["name"] == "Skip Octostate preflight for non-organization PRs" }
    provenance = steps.find { |step| step["name"] == "Check organization-change provenance" }
    resolve = steps.find { |step| step["name"] == "Resolve preflight status target" }
    preflight = steps.find { |step| step["name"] == "Preflight apply" }
    publish = steps.find { |step| step["name"] == "Publish preflight status" }

    refute_nil checkout
    refute_nil workflow_yaml
    refute_nil regression
    refute_nil setup_go
    refute_nil issue_tests
    refute_nil status_token
    refute_nil apply_token
    assert_nil skip
    refute_nil provenance
    refute_nil resolve
    refute_nil preflight
    refute_nil publish

    assert_includes checkout.fetch("if"), "github.event_name == 'pull_request'"
    refute_includes checkout.fetch("if"), "steps.detect.outputs.workflow_changed == 'true'"
    assert_includes workflow_yaml.fetch("if"), "github.event_name == 'pull_request' && steps.detect.outputs.workflow_changed == 'true'"
    assert_includes workflow_yaml.fetch("run"), '*.{yml,yaml}'
    assert_includes regression.fetch("run"), 'Dir["./test/*_test.rb"]'
    assert_equal "github.event_name != 'pull_request_target'", setup_go.fetch("if")
    assert_equal "tools/issue-to-config", issue_tests.fetch("working-directory")
    assert_includes issue_tests.fetch("run"), "go test ./..."
    assert_includes workflow_yaml.fetch("run"), "YAML.safe_load(File.read"
    refute_includes workflow_yaml.fetch("run"), "YAML.load_file"
    assert_equal "${{ github.event.repository.name }}", status_token.fetch("with").fetch("repositories")
    assert_equal "write", status_token.fetch("with").fetch("permission-statuses")
    assert_equal "read", status_token.fetch("with").fetch("permission-pull-requests")
    assert_equal "read", apply_token.fetch("with").fetch("permission-members")
    assert_equal "read", apply_token.fetch("with").fetch("permission-metadata")
    refute apply_token.fetch("with").key?("permission-statuses")
    assert_operator steps.index(status_token), :<, steps.index(provenance)
    assert_operator steps.index(status_token), :<, steps.index(resolve)
    assert_operator steps.index(status_token), :<, steps.index(publish)
    assert_equal "${{ steps.preflight-status-app-token.outputs.token }}", resolve.fetch("env").fetch("GH_TOKEN")
    assert_equal "${{ steps.preflight-status-app-token.outputs.token }}", publish.fetch("env").fetch("GH_TOKEN")
    assert_includes preflight.fetch("run"), '--token "${{ steps.preflight-read-app-token.outputs.token }}"'
    assert_operator steps.index(apply_token), :<, steps.index(preflight)
    assert_includes resolve.fetch("run"), "merge_commit_sha"
    assert_includes resolve.fetch("run"), "Octostate preflight"
    assert_includes publish.fetch("env").fetch("PRECHECK_SHA"), "merge_commit_sha"
    assert_equal "${{ job.status }}", publish.fetch("env").fetch("JOB_STATUS")
    assert_includes publish.fetch("run"), "No organization config change detected."
    assert_includes publish.fetch("run"), "Octostate preflight"
    assert_includes publish.fetch("if"), "always()"
  end
end
