package main

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

const baseConfig = `organization: orang-gaboets-test
members:
  - username: FerdiHS
    role: admin
invites: []
repositories:
  - name: existing
    visibility: private
teams:
  - slug: platform
    name: Platform
    privacy: closed
  - slug: maintainers
    name: Maintainers
    privacy: closed
`

func TestApplyRepositoryIssueMinimalPrivateRepository(t *testing.T) {
	updated := applyIssue(t, issueBody(map[string]string{
		"Repository name": "example-service",
		"Visibility":      "private",
	}))

	repo := findRepo(t, updated, "example-service")
	if repo.Visibility != "private" {
		t.Fatalf("unexpected visibility: %q", repo.Visibility)
	}
	if repo.Description != nil {
		t.Fatalf("description should be unmanaged, got %q", *repo.Description)
	}
}

func TestIsRepositoryRequestIssueAcceptsRepositoryLabel(t *testing.T) {
	event := repositoryIssueEvent{}
	event.Issue.Title = "Anything"
	event.Issue.Labels = []issueLabel{{Name: "repository"}}

	if !isRepositoryRequestIssue(event) {
		t.Fatal("expected repository label to identify repository request")
	}
}

func TestIsRepositoryRequestIssueAcceptsTitleFallback(t *testing.T) {
	event := repositoryIssueEvent{}
	event.Issue.Title = "Create repository: example-service"

	if !isRepositoryRequestIssue(event) {
		t.Fatal("expected title prefix to identify repository request")
	}
}

func TestIsRepositoryRequestIssueRejectsUnrelatedIssue(t *testing.T) {
	event := repositoryIssueEvent{}
	event.Issue.Title = "Create team: platform"
	event.Issue.Labels = []issueLabel{{Name: "team"}}

	if isRepositoryRequestIssue(event) {
		t.Fatal("did not expect unrelated issue to be identified as repository request")
	}
}

func TestApplyRepositoryIssueOptionalFields(t *testing.T) {
	updated := applyIssue(t, issueBody(map[string]string{
		"Repository name":        "example-service",
		"Visibility":             "public",
		"Description":            "Example service",
		"Homepage":               "https://example.com",
		"Topics":                 "platform\nservice",
		"Template repository":    "orang-gaboets-test/empty-template",
		"Teams with push access": "platform",
	}))

	repo := findRepo(t, updated, "example-service")
	if repo.Description == nil || *repo.Description != "Example service" {
		t.Fatalf("unexpected description: %#v", repo.Description)
	}
	if repo.Homepage == nil || *repo.Homepage != "https://example.com" {
		t.Fatalf("unexpected homepage: %#v", repo.Homepage)
	}
	if got := strings.Join(repo.Topics, ","); got != "platform,service" {
		t.Fatalf("unexpected topics: %q", got)
	}
	if repo.Template == nil || repo.Template.Owner != "orang-gaboets-test" || repo.Template.Name != "empty-template" {
		t.Fatalf("unexpected template: %#v", repo.Template)
	}

	team := findTeam(t, updated, "platform")
	if len(team.Repositories) != 1 {
		t.Fatalf("expected one team repository, got %#v", team.Repositories)
	}
	if team.Repositories[0].Name != "example-service" || team.Repositories[0].Permission != "push" {
		t.Fatalf("unexpected team repository permission: %#v", team.Repositories[0])
	}
}

func TestApplyRepositoryIssueTeamPermissionsGroupedByPermission(t *testing.T) {
	updated := applyIssue(t, issueBody(map[string]string{
		"Repository name":            "example-service",
		"Visibility":                 "private",
		"Teams with pull access":     "platform",
		"Teams with maintain access": "maintainers",
	}))

	platform := findTeam(t, updated, "platform")
	if platform.Repositories[0].Permission != "pull" {
		t.Fatalf("unexpected platform permission: %#v", platform.Repositories)
	}

	maintainers := findTeam(t, updated, "maintainers")
	if maintainers.Repositories[0].Permission != "maintain" {
		t.Fatalf("unexpected maintainers permission: %#v", maintainers.Repositories)
	}
}

func TestApplyRepositoryIssueRejectsDuplicateRepository(t *testing.T) {
	_, err := applyRepositoryIssue([]byte(baseConfig), issueBody(map[string]string{
		"Repository name": "existing",
		"Visibility":      "private",
	}))
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("expected duplicate repository error, got %v", err)
	}
}

func TestApplyRepositoryIssueRejectsInvalidRepositoryName(t *testing.T) {
	_, err := applyRepositoryIssue([]byte(baseConfig), issueBody(map[string]string{
		"Repository name": "bad/name",
		"Visibility":      "private",
	}))
	if err == nil || !strings.Contains(err.Error(), "must contain only ASCII") {
		t.Fatalf("expected invalid repository name error, got %v", err)
	}
}

func TestApplyRepositoryIssueRejectsTooLongRepositoryName(t *testing.T) {
	_, err := applyRepositoryIssue([]byte(baseConfig), issueBody(map[string]string{
		"Repository name": strings.Repeat("a", 101),
		"Visibility":      "private",
	}))
	if err == nil || !strings.Contains(err.Error(), "too long") {
		t.Fatalf("expected repository name length error, got %v", err)
	}
}

func TestApplyRepositoryIssueRejectsUnknownTeam(t *testing.T) {
	var cfg organizationConfig
	if err := yaml.Unmarshal([]byte(baseConfig), &cfg); err != nil {
		t.Fatalf("base config is not valid YAML: %v", err)
	}

	err := addRepositoryRequest(&cfg, repositoryRequest{
		Name:       "example-service",
		Visibility: "private",
		Teams: map[string][]string{
			"push": {"missing-team"},
		},
	})
	if err == nil || !strings.Contains(err.Error(), "not managed") {
		t.Fatalf("expected unknown team error, got %v", err)
	}
	if len(cfg.Repositories) != 1 {
		t.Fatalf("config should not be mutated on error, got repositories %#v", cfg.Repositories)
	}
}

func TestApplyRepositoryIssueRejectsTeamRepositoryCollisionWithoutMutation(t *testing.T) {
	configWithExistingTeamRepository := `organization: orang-gaboets-test
members: []
invites: []
repositories:
  - name: existing
    visibility: private
teams:
  - slug: platform
    name: Platform
    privacy: closed
    repositories:
      - name: example-service
        permission: pull
`

	var cfg organizationConfig
	if err := yaml.Unmarshal([]byte(configWithExistingTeamRepository), &cfg); err != nil {
		t.Fatalf("test config is not valid YAML: %v", err)
	}

	err := addRepositoryRequest(&cfg, repositoryRequest{
		Name:       "example-service",
		Visibility: "private",
		Teams: map[string][]string{
			"push": {"platform"},
		},
	})
	if err == nil || !strings.Contains(err.Error(), "already references") {
		t.Fatalf("expected team repository collision error, got %v", err)
	}
	if len(cfg.Repositories) != 1 {
		t.Fatalf("config should not add repository on error, got repositories %#v", cfg.Repositories)
	}
	if len(cfg.Teams[0].Repositories) != 1 {
		t.Fatalf("config should not add team repository on error, got repositories %#v", cfg.Teams[0].Repositories)
	}
}

func TestApplyRepositoryIssueRejectsUnknownTeamFromIssue(t *testing.T) {
	_, err := applyRepositoryIssue([]byte(baseConfig), issueBody(map[string]string{
		"Repository name":        "example-service",
		"Visibility":             "private",
		"Teams with push access": "missing-team",
	}))
	if err == nil || !strings.Contains(err.Error(), "not managed") {
		t.Fatalf("expected unknown team error, got %v", err)
	}
}

func TestApplyRepositoryIssueRejectsDuplicateTeamPermission(t *testing.T) {
	_, err := applyRepositoryIssue([]byte(baseConfig), issueBody(map[string]string{
		"Repository name":        "example-service",
		"Visibility":             "private",
		"Teams with pull access": "platform",
		"Teams with push access": "platform",
	}))
	if err == nil || !strings.Contains(err.Error(), "appears under both") {
		t.Fatalf("expected duplicate team permission error, got %v", err)
	}
}

func TestApplyRepositoryIssueRejectsMalformedTemplate(t *testing.T) {
	_, err := applyRepositoryIssue([]byte(baseConfig), issueBody(map[string]string{
		"Repository name":     "example-service",
		"Visibility":          "private",
		"Template repository": "not-a-template-reference",
	}))
	if err == nil || !strings.Contains(err.Error(), "owner/name") {
		t.Fatalf("expected malformed template error, got %v", err)
	}
}

func applyIssue(t *testing.T, body string) organizationConfig {
	t.Helper()

	updatedBytes, err := applyRepositoryIssue([]byte(baseConfig), body)
	if err != nil {
		t.Fatalf("applyRepositoryIssue() error = %v", err)
	}

	var updated organizationConfig
	if err := yaml.Unmarshal(updatedBytes, &updated); err != nil {
		t.Fatalf("updated config is not valid YAML: %v\n%s", err, string(updatedBytes))
	}
	return updated
}

func findRepo(t *testing.T, cfg organizationConfig, name string) repoSpec {
	t.Helper()
	for _, repo := range cfg.Repositories {
		if repo.Name == name {
			return repo
		}
	}
	t.Fatalf("repository %q not found in %#v", name, cfg.Repositories)
	return repoSpec{}
}

func findTeam(t *testing.T, cfg organizationConfig, slug string) teamSpec {
	t.Helper()
	for _, team := range cfg.Teams {
		if team.Slug == slug {
			return team
		}
	}
	t.Fatalf("team %q not found in %#v", slug, cfg.Teams)
	return teamSpec{}
}

func issueBody(fields map[string]string) string {
	labels := []string{
		"Repository name",
		"Visibility",
		"Description",
		"Homepage",
		"Topics",
		"Template repository",
		"Teams with pull access",
		"Teams with triage access",
		"Teams with push access",
		"Teams with maintain access",
		"Teams with admin access",
		"Reason",
	}

	var b strings.Builder
	for _, label := range labels {
		value := fields[label]
		if value == "" {
			value = "_No response_"
		}
		b.WriteString("### ")
		b.WriteString(label)
		b.WriteString("\n\n")
		b.WriteString(value)
		b.WriteString("\n\n")
	}
	return b.String()
}
