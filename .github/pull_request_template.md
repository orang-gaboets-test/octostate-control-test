## Summary

- <summary of change>

> Desired-state changes are applied after they land on `main` by the live apply
> workflow. It checks out the validated commit, revalidates
> `config/organization.yaml`, and uses the `OCTOSTATE_BOT_TOKEN` secret.

> Repository-request PRs are drafted with a dedicated GitHub App token so the
> organization-change validation and preflight checks can run on the resulting
> branch. Normal development PRs do not run octostate checks.

## Desired-state changes

- [ ] Updated `config/organization.yaml`
- [ ] Change came from an approved issue or documented request
- [ ] No unexpected live apply automation or credentials were added

## Validation

- [ ] `octostate config validate --config-dir ./config`
- [ ] `octostate config apply --config-dir ./config --check`
