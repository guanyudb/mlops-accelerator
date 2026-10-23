# Phase 6 - GitHub Actions

Wire the user's GitHub repository to the Databricks foundation. Gate 1 and Gate 2 live
here; Gate 3 is already armed on the Databricks side.

## Before you start: check the repository can enforce the gates

On the **GitHub Free** plan, both gates require a **public** repository:

- branch protection on a private repo returns *"Upgrade to GitHub Pro or make this
  repository public"*
- environment required reviewers are rejected on a private repo

A private repo will still let you create the `prod` environment, but it **will not pause**,
so `deploy-prod` runs straight through and Gate 2 silently disappears. Check visibility and
plan with the user before promising the gates:

```bash
gh repo view <OWNER>/<REPO> --json visibility,isPrivate
```

If it must stay private on Free, say plainly that Gates 1 and 2 will not be enforced and let
the user decide.

## Secrets and variable

Three secrets and one variable. **The user sets the secret value** - the agent must not
handle or echo it:

```bash
gh secret set DATABRICKS_HOST      --repo <OWNER>/<REPO> --body "<WORKSPACE_URL>"
gh secret set DATABRICKS_CLIENT_ID --repo <OWNER>/<REPO> --body "<APPLICATION_ID>"
gh secret set DATABRICKS_CLIENT_SECRET --repo <OWNER>/<REPO>     # user pastes at the prompt
gh variable set DATABRICKS_CATALOG --repo <OWNER>/<REPO> --body "<CATALOG>"
```

The catalog is a **variable**, not a secret, because it is not sensitive. Both workflows stop
with a clear message if it is missing.

## Gate 1 - branch protection on `main`

Require a pull request with **1 approving review** and the **`validate`** status check (the
check is named after the job in `churn-ci.yml`):

```bash
gh api -X PUT repos/<OWNER>/<REPO>/branches/main/protection --input - <<'JSON'
{"required_status_checks":{"strict":false,"contexts":["validate"]},
 "enforce_admins":false,
 "required_pull_request_reviews":{"required_approving_review_count":1},
 "restrictions":null}
JSON
```

GitHub does not let anyone approve their own pull request. A solo user needs a second
reviewer, or an admin merge (possible because `enforce_admins` is false). Say this up front.

## Gate 2 - the `prod` environment

```bash
REVIEWER_ID=$(gh api users/<REVIEWER_LOGIN> --jq .id)
gh api -X PUT repos/<OWNER>/<REPO>/environments/prod --input - <<JSON
{"reviewers":[{"type":"User","id":$REVIEWER_ID}],"deployment_branch_policy":null}
JSON
```

Verify the reviewer actually stuck - a 422 here usually means the private-repo limitation:

```bash
gh api repos/<OWNER>/<REPO>/environments/prod \
  --jq '[.protection_rules[] | select(.type=="required_reviewers") | .reviewers[].reviewer.login]'
```

## The `release` branch

Create it once from `main`. It records what production runs; nothing triggers from it, and
it should have **no** branch protection - the pipeline fast-forwards it after a successful
production deploy.

```bash
gh api repos/<OWNER>/<REPO>/git/refs -f ref=refs/heads/release \
  -f sha=$(gh api repos/<OWNER>/<REPO>/git/ref/heads/main --jq .object.sha)
```

## How the pipeline uses this

```
pull request -> main     churn-ci: validate + deploy to staging      (Gate 1: check + review)
merge to main            churn-cd: deploy-staging  -> train + register in staging
                                   deploy-prod     -> waits for the prod environment (Gate 2)
                                                      then deploy + train + register in prod
                                   promote         -> fast-forward release to this commit
new prod model version   parks until approved in Unity Catalog                   (Gate 3)
```

Then return to Phase 7 in [databricks-foundation.md](databricks-foundation.md).

> The workflows skip themselves when the repository is marked as a GitHub **template**
> (the shared accelerator repo). A copy made with "Use this template" or a plain clone pushed
> to a new repo is not a template, so CI runs normally there.
