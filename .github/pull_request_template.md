## Summary

- <summary of change>

> Desired-state changes are applied after they land on `main` by the live apply
> workflow. That workflow revalidates `config/organization.yaml` and uses the
> `OCTOSTATE_BOT_TOKEN` secret.

> Repository-request PRs are drafted with a dedicated GitHub App token so the
> normal PR validation and preflight checks can run on the resulting branch.

## Desired-state changes

- [ ] Updated `config/organization.yaml`
- [ ] Change came from an approved issue or documented request
- [ ] No unexpected live apply automation or credentials were added

## Validation

- [ ] `octostate config validate --config-dir ./config`
- [ ] `octostate config apply --config-dir ./config --check`
