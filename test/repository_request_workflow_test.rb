require "minitest/autorun"
require "yaml"

class RepositoryRequestWorkflowTest < Minitest::Test
  def workflow
    @workflow ||= YAML.safe_load(File.read(".github/workflows/repository-request.yml"), aliases: false)
  end

  def test_only_repository_label_triggers_drafting
    condition = workflow.fetch("jobs").fetch("create-draft-pr").fetch("if")
    steps = workflow.fetch("jobs").fetch("create-draft-pr").fetch("steps")
    token = steps.find { |step| step["name"] == "Create PR GitHub App token" }
    verify = steps.find { |step| step["name"] == "Verify PR App identity" }
    identity = steps.find { |step| step["name"] == "Resolve PR App commit identity" }
    draft = steps.find { |step| step["name"] == "Create draft pull request" }

    assert_includes condition, "contains(github.event.issue.labels.*.name, 'repository')"
    refute_includes condition, "Create repository:"
    refute workflow.fetch("permissions").key?("issues")
    refute_nil token
    refute_nil verify
    refute_nil identity
    refute_nil draft
    assert_equal "${{ vars.OCTOSTATE_PR_APP_CLIENT_ID }}", token.fetch("with").fetch("client-id")
    assert_equal "${{ secrets.OCTOSTATE_PR_APP_PRIVATE_KEY }}", token.fetch("with").fetch("private-key")
    assert_equal "write", token.fetch("with").fetch("permission-contents")
    assert_equal "write", token.fetch("with").fetch("permission-pull-requests")
    assert_equal "${{ vars.OCTOSTATE_PR_APP_LOGIN }}", verify.fetch("env").fetch("EXPECTED_APP_LOGIN")
    assert_equal "${{ steps.pr-app-token.outputs.app-slug }}[bot]", verify.fetch("env").fetch("ACTUAL_APP_LOGIN")
    assert_equal "${{ steps.pr-app-token.outputs.app-slug }}", identity.fetch("env").fetch("APP_SLUG")
    assert_equal "${{ steps.pr-app-token.outputs.token }}", draft.fetch("with").fetch("token")
    assert_equal "${{ steps.pr-app-identity.outputs.identity }}", draft.fetch("with").fetch("author")
    assert_equal "${{ steps.pr-app-identity.outputs.identity }}", draft.fetch("with").fetch("committer")
  end
end
