require "minitest/autorun"
require "yaml"

class ValidateWorkflowPreflightTest < Minitest::Test
  def workflow
    @workflow ||= YAML.load_file(".github/workflows/validate.yml")
  end

  def validate_job
    workflow.fetch("jobs").fetch("validate")
  end

  def test_publishes_octostate_preflight_status
    refute workflow.fetch("permissions").key?("statuses")

    steps = validate_job.fetch("steps")
    checkout = steps.find { |step| step["name"] == "Checkout" }
    workflow_yaml = steps.find { |step| step["name"] == "Validate workflow YAML" }
    token = steps.find { |step| step["name"] == "Create preflight GitHub App token" }
    resolve = steps.find { |step| step["name"] == "Resolve preflight status target" }
    publish = steps.find { |step| step["name"] == "Publish preflight status" }

    refute_nil checkout
    refute_nil workflow_yaml
    refute_nil token
    refute_nil resolve
    refute_nil publish

    assert_includes checkout.fetch("if"), "github.event_name == 'pull_request' && steps.detect.outputs.workflow_changed == 'true'"
    assert_includes workflow_yaml.fetch("if"), "github.event_name == 'pull_request' && steps.detect.outputs.workflow_changed == 'true'"
    assert_includes workflow_yaml.fetch("run"), '*.{yml,yaml}'
    assert_equal "write", token.fetch("with").fetch("permission-statuses")
    assert_equal "read", token.fetch("with").fetch("permission-pull-requests")
    assert_equal "${{ steps.preflight-app-token.outputs.token }}", resolve.fetch("env").fetch("GH_TOKEN")
    assert_equal "${{ steps.preflight-app-token.outputs.token }}", publish.fetch("env").fetch("GH_TOKEN")
    assert_operator steps.index(token), :<, steps.index(resolve)
    assert_operator steps.index(token), :<, steps.index(publish)
    assert_includes resolve.fetch("run"), "merge_commit_sha"
    assert_includes resolve.fetch("run"), "Octostate preflight"
    assert_includes publish.fetch("env").fetch("PRECHECK_SHA"), "merge_commit_sha"
    assert_equal "${{ job.status }}", publish.fetch("env").fetch("JOB_STATUS")
    assert_includes publish.fetch("run"), "Octostate preflight"
    assert_includes publish.fetch("if"), "always()"
  end
end
