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
validation before merge.
Repository-request issues are turned into draft PRs with a dedicated GitHub App
token so the resulting branches can run normal PR checks.

## Validation

Pull requests run a validate-only workflow that installs the pinned CLI version:

```bash
go install github.com/orang-gaboets/octostate/cmd/octostate@v1.1.0
octostate config validate --config-dir ./config
```

`octostate config validate` is offline and does not require GitHub credentials or
repository secrets. PR validation also runs `octostate config apply --check`
with a separate GitHub App token as a preflight gate before merge.

## Live Apply

When a change to `config/organization.yaml` lands on `main`, GitHub Actions runs
a second pass that:

1. checks out the pushed commit on `main`
2. validates the desired state again
3. runs `octostate config apply --config-dir ./config --token "$OCTOSTATE_BOT_TOKEN"`

That workflow uses a dedicated bot PAT stored in the `OCTOSTATE_BOT_TOKEN`
repository secret. `octostate config apply` only executes the supported
create/update portion of the plan; unsupported delete/remove drift is reported
but skipped.

## State Directory

`state/actual/` is reserved for future actual-state snapshots. This repository
keeps the directory present with `.gitkeep`, but live apply does not write
snapshots there.

## Scope

Open pull requests are validate-only by design. Live apply runs from `main` so
the desired state is reconciled as soon as it lands there.
