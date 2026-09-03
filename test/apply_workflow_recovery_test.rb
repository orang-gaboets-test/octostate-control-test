require "minitest/autorun"
require "yaml"

class ApplyWorkflowRecoveryTest < Minitest::Test
  def workflow
    @workflow ||= YAML.safe_load(File.read(".github/workflows/apply.yml"), aliases: false)
  end

  def test_failed_apply_has_manual_rerun_guidance
    steps = workflow.fetch("jobs").fetch("apply").fetch("steps")
    recovery = steps.find { |step| step["name"] == "Document apply recovery" }

    refute_nil recovery
    assert_includes recovery.fetch("if"), "failure() && steps.provenance.outputs.apply_required == 'true'"
    assert_includes recovery.fetch("run"), "validated commit is still current"
    assert_includes recovery.fetch("run"), "retry the live apply"
    assert_includes recovery.fetch("run"), "start a new validation/apply cycle"
  end
end
