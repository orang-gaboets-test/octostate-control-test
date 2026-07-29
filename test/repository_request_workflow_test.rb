require "minitest/autorun"
require "yaml"

class RepositoryRequestWorkflowTest < Minitest::Test
  def workflow
    @workflow ||= YAML.safe_load(File.read(".github/workflows/repository-request.yml"), aliases: false)
  end

  def test_only_repository_label_triggers_drafting
    condition = workflow.fetch("jobs").fetch("create-draft-pr").fetch("if")

    assert_includes condition, "contains(github.event.issue.labels.*.name, 'repository')"
    refute_includes condition, "Create repository:"
    refute workflow.fetch("permissions").key?("issues")
  end
end
