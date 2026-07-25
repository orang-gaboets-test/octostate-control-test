require "minitest/autorun"
require "yaml"

class ApplyWorkflowRecoveryTest < Minitest::Test
  def workflow
    @workflow ||= YAML.load_file(".github/workflows/apply.yml")
  end

  def test_failed_apply_has_manual_rerun_guidance
    steps = workflow.fetch("jobs").fetch("apply").fetch("steps")
    recovery = steps.find { |step| step["name"] == "Document apply recovery" }

    refute_nil recovery
    assert_includes recovery.fetch("if"), "failure() && steps.provenance.outputs.apply_required == 'true'"
    assert_includes recovery.fetch("run"), "Re-run this workflow run"
    assert_includes recovery.fetch("run"), "same validated commit"
  end
end
