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
    assert_equal "write", workflow.fetch("permissions").fetch("statuses")

    steps = validate_job.fetch("steps")
    resolve = steps.find { |step| step["name"] == "Resolve preflight status target" }
    publish = steps.find { |step| step["name"] == "Publish preflight status" }

    refute_nil resolve
    refute_nil publish

    assert_includes resolve.fetch("run"), "merge_commit_sha"
    assert_includes resolve.fetch("run"), "Octostate preflight"
    assert_includes publish.fetch("env").fetch("PRECHECK_SHA"), "merge_commit_sha"
    assert_equal "${{ job.status }}", publish.fetch("env").fetch("JOB_STATUS")
    assert_includes publish.fetch("run"), "Octostate preflight"
    assert_includes publish.fetch("if"), "always()"
  end
end
