## Summary

- <summary of change>

> Desired-state changes are applied after they land on `main` by the live apply
> workflow. It checks out the validated commit, revalidates
> `config/organization.yaml`, and uses a short-lived token from the Apply GitHub
> App.

> Repository-request PRs are drafted with a dedicated GitHub App token so the
> organization-change validation and preflight checks can run on the resulting
> branch. All PRs run the trusted preflight gate in CI; only organization-change
> PRs can later drive live apply on `main`.

## Desired-state changes

- [ ] Updated `config/organization.yaml`
- [ ] Change came from an approved issue or documented request
- [ ] No unexpected live apply automation or credentials were added

## Validation

- [ ] `octostate config validate --config-dir ./config`
- [ ] Trusted preflight passed in CI (`octostate config apply --config-dir ./config --check`)
