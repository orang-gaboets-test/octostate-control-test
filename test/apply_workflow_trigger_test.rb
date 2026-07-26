require "minitest/autorun"
require "yaml"

class ApplyWorkflowTriggerTest < Minitest::Test
  def workflow
    @workflow ||= YAML.load_file(".github/workflows/apply.yml")
  end

  def apply_job
    workflow.fetch("jobs").fetch("apply")
  end

  def test_verifies_the_upstream_workflow_path
    steps = apply_job.fetch("steps")
    trigger = steps.find { |step| step["name"] == "Verify triggering workflow path" }
    checkout = steps.find { |step| step["name"] == "Checkout validated commit" }
    provenance = steps.find { |step| step["name"] == "Verify apply provenance" }

    refute_nil trigger
    refute_nil checkout
    refute_nil provenance

    assert_equal "${{ github.token }}", trigger.fetch("env").fetch("GH_TOKEN")
    assert_includes trigger.fetch("run"), "actions/runs/$RUN_ID"
    assert_includes trigger.fetch("run"), ".github/workflows/validate.yml@*"
    assert_includes trigger.fetch("run"), "Unexpected triggering workflow path"
    assert_operator steps.index(trigger), :<, steps.index(provenance)
    assert_equal false, checkout.fetch("with").fetch("persist-credentials")
  end
end
