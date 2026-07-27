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
repository secrets. For authorized organization-change PRs, the trusted
preflight App publishes an `Octostate preflight` status on the PR merge SHA and
then runs `octostate config apply --check` with its own GitHub App token as the
trusted preflight gate before merge.

PRs that change `config/organization.yaml` fail unless all of the following are
true:

- the head repository is this repository
- the head branch starts with `automation/repository-request-`
- the PR author login exactly matches the `OCTOSTATE_PR_APP_LOGIN` repository
  variable

Normal development PRs and fork PRs pass only when they do not change
`config/organization.yaml`. The workflow uses `pull_request` for unprivileged
validation and `pull_request_target` for the App-secret preflight; the trusted
base-branch definition checks out the generated PR merge ref only as
configuration input and does not execute code from the PR. The `main` branch
ruleset should follow the Main Branch Ruleset section below.

Pushes to `main` must be single-commit pushes or merge results that land as a
single commit. Multi-commit pushes fail validation so live apply can keep a
clear provenance trail for the config blob being reconciled.

## GitHub App Setup

The repository uses three dedicated GitHub Apps, which mint four short-lived
token roles across the workflows:

- `OCTOSTATE_PR_APP_CLIENT_ID` and `OCTOSTATE_PR_APP_PRIVATE_KEY` power the
  repository-request workflow that drafts PRs from issues.
- `OCTOSTATE_PREFLIGHT_APP_CLIENT_ID` and
  `OCTOSTATE_PREFLIGHT_APP_PRIVATE_KEY` power the organization-change PR
  preflight checks. The workflow mints a repository-scoped status token for
  `Octostate preflight` and a separate read token for `octostate config
  apply --check`. Set `OCTOSTATE_PR_APP_LOGIN` to the exact login of the PR
  App's bot user, including the `[bot]` suffix. Install the preflight App on the
  organization with read access to pull requests, organization members, and
  repository metadata plus commit-status write access, and grant it access to
  all repositories whose state is managed here.
- `OCTOSTATE_APPLY_APP_CLIENT_ID` and `OCTOSTATE_APPLY_APP_PRIVATE_KEY` power
  the live apply workflow after changes land on `main`. The workflow mints a
  short-lived installation token from the Apply App and uses it for
  `octostate config apply`.

Install the Apply App with:

- Repository access: All repositories
- Administration: Read and write
- Contents: Read-only
- Members: Read and write
- Metadata: Read-only

The organization must also allow GitHub Apps to create every repository
visibility supported by the request workflow.

Install the PR App on this repository with contents and pull-request write
access. Install the preflight and apply Apps on the `orang-gaboets-test`
organization and grant only the permissions needed for the workflow they serve.

## Maintainer Checklist

After creating the GitHub Apps, do this in order:

1. Install the PR App on this repository and the preflight and apply Apps on
   the `orang-gaboets-test` organization.
2. Leave webhooks disabled on all three apps.
3. Store each app's client ID in a repository variable and each private key in
   a repository secret.
4. Set `OCTOSTATE_PR_APP_LOGIN` to the PR App bot login and add the branch
   rulesets described below.
5. Smoke test the flow by opening a repository issue to draft a PR, then an
   organization-change PR to confirm validation and preflight run.

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

## Main Branch Ruleset

Apply a manual GitHub branch ruleset to `main` that:

- requires pull requests
- requires `Validate desired state` with GitHub Actions as the expected source
- requires `Octostate preflight` with the dedicated preflight App as the expected source
- blocks direct pushes
- blocks force pushes
- blocks deletion
- keeps merged config changes to one commit, preferably by squash merge
- avoids human or admin bypass entries for desired-state changes

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
6. mints a short-lived token from the `Octostate Apply` GitHub App and runs
   `octostate config apply --config-dir ./config --token "<app-token>"`
7. checks whether `main` changed desired state during the apply and records a
   stale result

That workflow uses the short-lived installation token from the `Octostate
Apply` GitHub App. `octostate config apply` only executes the supported
create/update portion of the plan; unsupported delete/remove drift is reported
but skipped. Documentation-only commits on `main` stay validation-only and do
not trigger live apply. A newer successful validation run can reconcile the
current desired state, but stale apply runs fail visibly and may need another
validation/apply cycle. If a live apply run fails after it starts, re-run that
same workflow run from the Actions tab to retry the validated commit; if main
has moved to a different desired-state blob, start a new validation/apply
cycle instead. Direct pushes or unqualified commits that change
`config/organization.yaml` fail before checkout and before the live-apply
token is used.

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
