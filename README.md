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

The initial desired state is intentionally empty:

- no durable organization members
- no pending invites
- no managed repositories
- no managed teams

Open issues with the provided templates when a member invite, team, or repository
should be added. A pull request should update `config/organization.yaml` and pass
validation before merge.

## Validation

Pull requests run a validate-only workflow that installs the pinned CLI version:

```bash
go install github.com/orang-gaboets/octostate/cmd/octostate@v1.0.0
octostate config validate --config-dir ./config
```

`octostate config validate` is offline and does not require GitHub credentials or
repository secrets.

## State Directory

`state/actual/` is reserved for future actual-state snapshots. This first version
keeps the directory present with `.gitkeep` but does not collect, diff, plan, or
apply live GitHub state.

## Scope

This first scaffold is validate-only by design. Live apply automation should be
added later only after the organization authentication model, approval policy,
and rollout process are agreed upon.
