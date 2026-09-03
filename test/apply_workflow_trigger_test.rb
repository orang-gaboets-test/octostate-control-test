require "minitest/autorun"
require "yaml"

class ApplyWorkflowTriggerTest < Minitest::Test
  def workflow
    @workflow ||= YAML.safe_load(File.read(".github/workflows/apply.yml"), aliases: false)
  end

  def apply_job
    workflow.fetch("jobs").fetch("apply")
  end

  def test_verifies_the_upstream_workflow_path
    assert_equal "read", workflow.fetch("permissions").fetch("actions")

    steps = apply_job.fetch("steps")
    trigger = steps.find { |step| step["name"] == "Verify triggering workflow path" }
    checkout = steps.find { |step| step["name"] == "Checkout validated commit" }
    provenance = steps.find { |step| step["name"] == "Verify apply provenance" }
    app_token = steps.find { |step| step["name"] == "Create apply GitHub App token" }
    apply = steps.find { |step| step["name"] == "Apply config if validated commit is still current" }

    refute_nil trigger
    refute_nil checkout
    refute_nil provenance
    refute_nil app_token
    refute_nil apply

    assert_equal "${{ github.token }}", trigger.fetch("env").fetch("GH_TOKEN")
    assert_includes trigger.fetch("run"), "actions/runs/$RUN_ID"
    assert_includes trigger.fetch("run"), ".github/workflows/validate.yml"
    refute_includes trigger.fetch("run"), ".github/workflows/validate.yml@"
    assert_includes trigger.fetch("run"), "Unexpected triggering workflow path"
    assert_operator steps.index(trigger), :<, steps.index(provenance)
    refute checkout.fetch("with").key?("persist-credentials")
    assert_equal "${{ vars.OCTOSTATE_APPLY_APP_CLIENT_ID }}", app_token.fetch("with").fetch("client-id")
    assert_equal "${{ secrets.OCTOSTATE_APPLY_APP_PRIVATE_KEY }}", app_token.fetch("with").fetch("private-key")
    assert_equal "${{ github.repository_owner }}", app_token.fetch("with").fetch("owner")
    assert_equal "write", app_token.fetch("with").fetch("permission-administration")
    assert_equal "read", app_token.fetch("with").fetch("permission-contents")
    assert_equal "write", app_token.fetch("with").fetch("permission-members")
    assert_equal "read", app_token.fetch("with").fetch("permission-metadata")
    assert_equal "${{ steps.apply-app-token.outputs.token }}", apply.fetch("env").fetch("OCTOSTATE_APPLY_TOKEN")
    assert_includes apply.fetch("run"), '--token "$OCTOSTATE_APPLY_TOKEN"'
    refute_includes File.read(".github/workflows/apply.yml"), "OCTOSTATE_BOT_TOKEN"
  end
end
