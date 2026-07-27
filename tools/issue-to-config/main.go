package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

type repositoryIssueEvent struct {
	Issue struct {
		Number int          `json:"number"`
		Title  string       `json:"title"`
		Body   string       `json:"body"`
		Labels []issueLabel `json:"labels"`
	} `json:"issue"`
}

type issueLabel struct {
	Name string `json:"name"`
}

type organizationConfig struct {
	Organization string       `yaml:"organization"`
	Members      []memberSpec `yaml:"members"`
	Invites      []inviteSpec `yaml:"invites"`
	Repositories []repoSpec   `yaml:"repositories"`
	Teams        []teamSpec   `yaml:"teams"`
}

type memberSpec struct {
	Username string `yaml:"username"`
	Role     string `yaml:"role"`
}

type inviteSpec struct {
	Username  *string  `yaml:"username,omitempty"`
	Email     *string  `yaml:"email,omitempty"`
	UserID    *int64   `yaml:"user_id,omitempty"`
	Role      string   `yaml:"role,omitempty"`
	TeamSlugs []string `yaml:"team_slugs,omitempty"`
}

type repoSpec struct {
	Owner        string        `yaml:"owner,omitempty"`
	Name         string        `yaml:"name"`
	Template     *templateSpec `yaml:"template,omitempty"`
	Visibility   string        `yaml:"visibility"`
	Description  *string       `yaml:"description,omitempty"`
	Homepage     *string       `yaml:"homepage,omitempty"`
	Topics       []string      `yaml:"topics,omitempty"`
	AllowForking *bool         `yaml:"allow_forking,omitempty"`
	Archived     *bool         `yaml:"archived,omitempty"`
	IsTemplate   *bool         `yaml:"is_template,omitempty"`
}

type templateSpec struct {
	Owner              string `yaml:"owner"`
	Name               string `yaml:"name"`
	IncludeAllBranches bool   `yaml:"include_all_branches,omitempty"`
}

type teamSpec struct {
	Slug         string           `yaml:"slug"`
	Name         string           `yaml:"name"`
	Description  string           `yaml:"description,omitempty"`
	Privacy      string           `yaml:"privacy,omitempty"`
	ParentSlug   string           `yaml:"parent_slug,omitempty"`
	Members      []teamMemberSpec `yaml:"members,omitempty"`
	Repositories []teamRepoSpec   `yaml:"repositories,omitempty"`
}

type teamMemberSpec struct {
	Username string `yaml:"username"`
	Role     string `yaml:"role,omitempty"`
}

type teamRepoSpec struct {
	Owner      string `yaml:"owner,omitempty"`
	Name       string `yaml:"name"`
	Permission string `yaml:"permission"`
}

type repositoryRequest struct {
	Name        string
	Visibility  string
	Description string
	Homepage    string
	Topics      []string
	Template    *templateSpec
	Teams       map[string][]string
}

var permissionLabels = map[string]string{
	"pull":     "Teams with pull access",
	"triage":   "Teams with triage access",
	"push":     "Teams with push access",
	"maintain": "Teams with maintain access",
	"admin":    "Teams with admin access",
}

func main() {
	eventPath := flag.String("event-path", os.Getenv("GITHUB_EVENT_PATH"), "path to GitHub event JSON")
	configPath := flag.String("config", "config/organization.yaml", "path to organization.yaml")
	flag.Parse()

	if err := run(*eventPath, *configPath); err != nil {
		fmt.Fprintf(os.Stderr, "issue-to-config: %v\n", err)
		os.Exit(1)
	}
}

func run(eventPath, configPath string) error {
	if strings.TrimSpace(eventPath) == "" {
		return errors.New("event path is required; pass --event-path or set GITHUB_EVENT_PATH")
	}

	eventBytes, err := os.ReadFile(eventPath)
	if err != nil {
		return fmt.Errorf("read event file: %w", err)
	}

	var event repositoryIssueEvent
	if err := json.Unmarshal(eventBytes, &event); err != nil {
		return fmt.Errorf("parse event JSON: %w", err)
	}
	if !isRepositoryRequestIssue(event) {
		return errors.New("issue is not a repository request")
	}

	configBytes, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("read config: %w", err)
	}

	updated, err := applyRepositoryIssue(configBytes, event.Issue.Body)
	if err != nil {
		return err
	}

	if err := os.WriteFile(configPath, updated, 0o644); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	return nil
}

func isRepositoryRequestIssue(event repositoryIssueEvent) bool {
	return hasLabel(event.Issue.Labels, "repository")
}

func hasLabel(labels []issueLabel, want string) bool {
	for _, label := range labels {
		if strings.EqualFold(label.Name, want) {
			return true
		}
	}
	return false
}

func applyRepositoryIssue(configBytes []byte, body string) ([]byte, error) {
	var cfg organizationConfig
	if err := yaml.Unmarshal(configBytes, &cfg); err != nil {
		return nil, fmt.Errorf("parse organization config: %w", err)
	}

	request, err := parseRepositoryRequest(body)
	if err != nil {
		return nil, err
	}
	if err := addRepositoryRequest(&cfg, request); err != nil {
		return nil, err
	}

	var out bytes.Buffer
	encoder := yaml.NewEncoder(&out)
	encoder.SetIndent(2)
	if err := encoder.Encode(&cfg); err != nil {
		return nil, fmt.Errorf("encode organization config: %w", err)
	}
	if err := encoder.Close(); err != nil {
		return nil, fmt.Errorf("close YAML encoder: %w", err)
	}
	return out.Bytes(), nil
}

func parseRepositoryRequest(body string) (repositoryRequest, error) {
	sections := parseIssueFormSections(body)

	request := repositoryRequest{
		Name:       valueSection(sections, "Repository name"),
		Visibility: valueSection(sections, "Visibility"),
		Topics:     listSection(sections, "Topics"),
		Teams:      make(map[string][]string, len(permissionLabels)),
	}
	request.Description = valueSection(sections, "Description")
	request.Homepage = valueSection(sections, "Homepage")

	if request.Name == "" {
		return repositoryRequest{}, errors.New("repository name is required")
	}
	if err := validateRepositoryName(request.Name); err != nil {
		return repositoryRequest{}, err
	}
	switch request.Visibility {
	case "private", "public":
	default:
		return repositoryRequest{}, fmt.Errorf("visibility must be private or public, got %q", request.Visibility)
	}

	if templateValue := valueSection(sections, "Template repository"); templateValue != "" {
		parsed, err := parseTemplateRepository(templateValue)
		if err != nil {
			return repositoryRequest{}, err
		}
		request.Template = parsed
	}

	teamPermissionBySlug := map[string]string{}
	for _, permission := range sortedPermissions() {
		for _, slug := range listSection(sections, permissionLabels[permission]) {
			key := strings.ToLower(slug)
			if existing, ok := teamPermissionBySlug[key]; ok {
				return repositoryRequest{}, fmt.Errorf("team %q appears under both %s and %s access", slug, existing, permission)
			}
			teamPermissionBySlug[key] = permission
			request.Teams[permission] = append(request.Teams[permission], slug)
		}
	}

	return request, nil
}

func validateRepositoryName(name string) error {
	if len(name) > 100 {
		return fmt.Errorf("repository name %q is too long; maximum length is 100 characters", name)
	}
	if name == "." || name == ".." {
		return fmt.Errorf("repository name %q is not allowed", name)
	}
	for i := 0; i < len(name); i++ {
		if !isRepositoryNameChar(name[i]) {
			return fmt.Errorf("repository name %q must contain only ASCII letters, digits, dots, hyphens, or underscores", name)
		}
	}
	return nil
}

func isRepositoryNameChar(c byte) bool {
	return (c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '.' ||
		c == '-' ||
		c == '_'
}

func parseTemplateRepository(value string) (*templateSpec, error) {
	parts := strings.Split(value, "/")
	if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" || strings.TrimSpace(parts[1]) == "" {
		return nil, fmt.Errorf("template repository must use owner/name format, got %q", value)
	}
	return &templateSpec{
		Owner: strings.TrimSpace(parts[0]),
		Name:  strings.TrimSpace(parts[1]),
	}, nil
}

func addRepositoryRequest(cfg *organizationConfig, request repositoryRequest) error {
	for _, repo := range cfg.Repositories {
		owner := strings.TrimSpace(repo.Owner)
		if owner == "" {
			owner = cfg.Organization
		}
		if strings.EqualFold(owner, cfg.Organization) && strings.EqualFold(repo.Name, request.Name) {
			return fmt.Errorf("repository %q already exists in config", request.Name)
		}
	}

	teamIndex := make(map[string]int, len(cfg.Teams))
	for i, team := range cfg.Teams {
		teamIndex[strings.ToLower(team.Slug)] = i
	}

	for _, permission := range sortedPermissions() {
		for _, slug := range request.Teams[permission] {
			index, ok := teamIndex[strings.ToLower(slug)]
			if !ok {
				return fmt.Errorf("team %q is not managed in config", slug)
			}
			if teamHasRepository(cfg.Teams[index], cfg.Organization, request.Name) {
				return fmt.Errorf("team %q already references repository %q", slug, request.Name)
			}
		}
	}

	newRepo := repoSpec{
		Name:       request.Name,
		Visibility: request.Visibility,
		Topics:     request.Topics,
		Template:   request.Template,
	}
	if request.Description != "" {
		newRepo.Description = &request.Description
	}
	if request.Homepage != "" {
		newRepo.Homepage = &request.Homepage
	}
	cfg.Repositories = append(cfg.Repositories, newRepo)

	for _, permission := range sortedPermissions() {
		for _, slug := range request.Teams[permission] {
			index := teamIndex[strings.ToLower(slug)]
			cfg.Teams[index].Repositories = append(cfg.Teams[index].Repositories, teamRepoSpec{
				Name:       request.Name,
				Permission: permission,
			})
		}
	}

	return nil
}

func teamHasRepository(team teamSpec, organization, name string) bool {
	for _, repo := range team.Repositories {
		owner := strings.TrimSpace(repo.Owner)
		if owner == "" {
			owner = organization
		}
		if strings.EqualFold(owner, organization) && strings.EqualFold(repo.Name, name) {
			return true
		}
	}
	return false
}

func parseIssueFormSections(body string) map[string]string {
	sections := map[string]string{}
	var current string
	var lines []string
	inCodeBlock := false

	flush := func() {
		if current == "" {
			return
		}
		sections[current] = strings.TrimSpace(strings.Join(lines, "\n"))
		lines = nil
	}

	for _, rawLine := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		trimmedLine := strings.TrimSpace(rawLine)
		if strings.HasPrefix(trimmedLine, "```") {
			inCodeBlock = !inCodeBlock
			continue
		}
		if !inCodeBlock && strings.HasPrefix(rawLine, "### ") {
			flush()
			current = strings.TrimSpace(strings.TrimPrefix(rawLine, "### "))
			continue
		}
		if current != "" {
			lines = append(lines, rawLine)
		}
	}
	flush()

	return sections
}

func valueSection(sections map[string]string, label string) string {
	value := strings.TrimSpace(sections[label])
	if value == "_No response_" {
		return ""
	}
	return value
}

func listSection(sections map[string]string, label string) []string {
	value := valueSection(sections, label)
	if value == "" {
		return nil
	}

	var values []string
	for _, line := range strings.Split(value, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || trimmed == "_No response_" {
			continue
		}
		values = append(values, trimmed)
	}
	return values
}

func sortedPermissions() []string {
	permissions := make([]string, 0, len(permissionLabels))
	for permission := range permissionLabels {
		permissions = append(permissions, permission)
	}
	sort.Slice(permissions, func(i, j int) bool {
		return permissionRank(permissions[i]) < permissionRank(permissions[j])
	})
	return permissions
}

func permissionRank(permission string) int {
	switch permission {
	case "pull":
		return 0
	case "triage":
		return 1
	case "push":
		return 2
	case "maintain":
		return 3
	case "admin":
		return 4
	default:
		return 99
	}
}
