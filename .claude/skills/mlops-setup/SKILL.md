---
name: mlops-setup
description: Set up a governed three-gate MLOps pipeline on Databricks from this repository. Asks which CI/CD platform (GitHub Actions or Azure DevOps) and whether to run the bundled advanced churn demo or bring your own model, then deploys the bundle across dev/staging/prod, wires the CI service principal and the Unity Catalog model-approval gate, and configures the platform's review and release gates. Use when someone has cloned or copied this repo and wants MLOps running, or asks how to adapt it to their own model or CI/CD platform.
---

# Set up MLOps from this repository

Take someone from a fresh copy of this repo to a working pipeline: one codebase promoted
dev -> staging -> prod, with three human approval gates.

```
Gate 1  code review           pull request into main: CI check + reviewer approval
Gate 2  pre-production release  production deploy pauses until a human approves
Gate 3  model approval        new production model version parks in Unity Catalog
                              until a human approves it; then it is promoted to
                              @Champion and the serving endpoint updates
```

Stages are **schemas in one catalog** of one workspace. Production owns the data; dev and
staging read it, so there are no copies to drift.

## Step 1 - Ask before doing anything

Ask these together, in one round. Do not start until you have the answers.

1. **CI/CD platform** - GitHub Actions, or Azure DevOps (Azure Repos + Azure Pipelines)?
2. **Starting point** - run the included advanced churn demo as is (fastest; good for
   learning and demos), or use it as the scaffold for their own model?
3. **Databricks** - which CLI profile, and which **existing** catalog can they create schemas
   in? (Many workspaces cannot create catalogs at all - see Phase 0.)
4. **Repository** - where their copy will live (GitHub `owner/repo`, or Azure DevOps
   org / project / repo), and who should approve production releases?
5. **Optional extras** - do they want the real-time serving endpoint and Lakehouse
   Monitoring (drift detection)?

Everything else is derived, not asked: the workspace URL and the user's email come from the
profile (`databricks auth profiles`, `databricks current-user me`), and the service principal's
ids come out of Phase 4.

Then branch on the answers:

- **Separate workspaces per stage** (dev, staging and prod in different workspaces) - not
  supported in this version. Say so plainly, offer the single-workspace setup, and do not
  improvise a multi-workspace layout.
- **GitHub with a private repository on the Free plan** - Gates 1 and 2 cannot be enforced
  there. Raise it now, before any work; see [references/github-actions.md](references/github-actions.md).
- **Their own model** - read [references/bring-your-own-model.md](references/bring-your-own-model.md)
  with them first, and recommend getting the churn demo working end to end before swapping
  anything in.
- **No CLI profile yet** - they run `databricks auth login --host <workspace-url> --profile <name>`
  (it opens a browser, so it has to be them).

## Step 2 - Follow the path

| Phase | What | Where |
|---|---|---|
| 0-5 | Access, schemas, bundle, data, service principal, first model, Gate 3 | [references/databricks-foundation.md](references/databricks-foundation.md) |
| 6 | Gates 1 and 2 on their platform | [references/github-actions.md](references/github-actions.md) or [references/azure-devops.md](references/azure-devops.md) |
| 7 | Verify everything as the service principal | back to [references/databricks-foundation.md](references/databricks-foundation.md) |
| - | Their own model | [references/bring-your-own-model.md](references/bring-your-own-model.md) |
| - | Anything fails, or a limitation applies | [references/troubleshooting.md](references/troubleshooting.md) |

**Verify each phase before starting the next.** A later phase failing nearly always means an
earlier check was skipped.

## Rules

- **Never guess** a catalog, workspace URL, application id or repository - ask.
- **Never print, log or echo a service principal secret.** The user creates the service
  principal, mints its secret, and types secret values in themselves.
- **Ask before anything outward-facing** - creating repositories, pushing, opening pull
  requests, changing repository settings.
- **Do not weaken a gate to get past it.** If a solo user cannot approve their own pull
  request, explain the options (a second reviewer, or an admin override the user chooses to
  use); do not disable the policy.
- **Judge success by exit codes and resulting state, not output wording.** CLI messages
  differ between versions: a good `bundle validate` prints `Validation OK!` or
  `Found 1 warning`, and a good `bundle deploy` prints `Deployment complete!` or a
  `Resources: ... unchanged` summary.
- **On a shared workspace, write only into a catalog the user owns.**

## Done means

- 12 jobs exist (4 per stage)
- production holds the feature and label tables; dev and staging hold none
- the production deployment job reports `deployment_job_state: CONNECTED`
- a newly registered production version **parked**: `Approval_Check` failed with
  *"Model version not approved for deployment"*, and approving it promoted it to `@champion`
- on their platform: a test pull request ran the `validate` check, the production deploy
  paused for approval, and `release` moved only after production deployed

Report anything you could not verify as unverified - do not round it up to done.
