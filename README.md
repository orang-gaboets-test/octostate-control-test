# octostate-control-test

This repository is a minimal GitOps control repo for managing the desired state of
the `orang-gaboets-test` GitHub organization with the `octostate` CLI.

The control repo owns the review workflow and desired-state files. The
`octostate` project remains an external command-line dependency installed by CI;
this repository does not import `octostate` as a Go library.

## Desired State

The source of truth is:

```text
config/
  organization.yaml
```

The initial desired state is an adopted baseline from `orang-gaboets-test`:

- durable organization members currently present in the org
- no pending invites
- repositories currently managed by the org
- teams currently present in the org

Open issues with the provided templates when a member invite, team, or repository
should be added. A pull request should update `config/organization.yaml` and pass
the applicable checks before merge.
Repository-request issues are turned into draft PRs with a dedicated GitHub App
token so the resulting branches can run organization-change checks.

## Validation

All PRs run the validation workflow so the required check always reports a
clear pass or fail. PRs that do not change `config/organization.yaml` pass
without running `octostate`. Authorized organization-change PRs run the pinned
CLI version:

```bash
go install github.com/orang-gaboets/octostate/cmd/octostate@v1.1.0
octostate config validate --config-dir ./config
```

`octostate config validate` is offline and does not require GitHub credentials or
repository secrets. For authorized organization-change PRs, the same workflow
runs `octostate config apply --check` with a separate GitHub App token as a
preflight gate before merge.

PRs that change `config/organization.yaml` fail unless all of the following are
true:

- the head repository is this repository
- the head branch starts with `automation/repository-request-`
- the PR author login exactly matches the `OCTOSTATE_PR_APP_LOGIN` repository
  variable

Normal development PRs and fork PRs pass only when they do not change
`config/organization.yaml`. The workflow uses `pull_request_target` so its
trusted base-branch definition can handle the App secret; it checks out the
generated PR merge ref only as configuration input and does not execute code from
the PR.

## GitHub App Setup

The repository uses two short-lived GitHub App tokens and one live-apply secret:

- `OCTOSTATE_PR_APP_CLIENT_ID` and `OCTOSTATE_PR_APP_PRIVATE_KEY` power the
  repository-request workflow that drafts PRs from issues.
- `OCTOSTATE_PREFLIGHT_APP_CLIENT_ID` and
  `OCTOSTATE_PREFLIGHT_APP_PRIVATE_KEY` power the organization-change PR
  preflight check. Set `OCTOSTATE_PR_APP_LOGIN` to the exact login of the PR
  App's bot user, including the `[bot]` suffix. Install the preflight App on the
  organization with read access to organization members and repository metadata,
  and grant it access to all repositories whose state is managed here.
- `OCTOSTATE_BOT_TOKEN` powers the live apply workflow after changes land on
  `main`.

Install the PR App on this repository with contents and pull-request write
access. Install both apps on the `orang-gaboets-test` organization and grant only
the permissions needed for the workflow they serve.

## App-Only Branch Provenance

Apply a manual GitHub branch ruleset to `automation/repository-request-*` so
only the dedicated PR App can create and update repository-request branches.
Configure the ruleset to:

- set enforcement status to `Active`
- restrict creations
- restrict updates
- restrict deletions
- block force pushes
- allow only the dedicated PR App as a bypass actor with `Always allow`

Do not add human or admin bypass entries. This ruleset is a GitHub repository
setting, not a file stored in this repository.

## Live Apply

When a change to `config/organization.yaml` lands on `main`, GitHub Actions waits
for the `Validate octostate config` workflow on that same commit, then runs a
second pass that:

1. verifies config-changing commits came from a merged same-repo PR authored by
   the dedicated PR App on an `automation/repository-request-*` branch
2. checks out the validated commit
3. revalidates the desired state
4. compares the validated `config/organization.yaml` blob with current `main`
5. skips the apply only if current `main` has a different desired-state blob
6. runs `octostate config apply --config-dir ./config --token "$OCTOSTATE_BOT_TOKEN"`
7. checks whether `main` changed desired state during the apply and records a
   stale result

That workflow uses a dedicated bot PAT stored in the `OCTOSTATE_BOT_TOKEN`
repository secret. `octostate config apply` only executes the supported
create/update portion of the plan; unsupported delete/remove drift is reported
but skipped. Documentation-only commits on `main` do not block apply when the
desired-state blob is unchanged. A newer successful validation run automatically
queues the apply for changed desired state, so a stale apply converges to the
current desired state. Direct pushes or unqualified commits that change
`config/organization.yaml` fail before checkout and before the live-apply token
is used.

## State Directory

`state/actual/` is reserved for future actual-state snapshots. This repository
keeps the directory present with `.gitkeep`, but live apply does not write
snapshots there.

## Scope

Only PRs generated from organization-change issues by the dedicated PR App run
octostate validation and preflight. Normal repository-development PRs and fork
PRs are outside that workflow. Live apply runs after a successful validation of
`config/organization.yaml` on `main`, reconciling the exact commit that passed
checks rather than whatever the branch looks like later.
