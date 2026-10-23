# Setup guide

How to stand this project up in your own Databricks workspace and CI/CD platform by hand. If
you use Claude Code, the `mlops-setup` skill walks the same steps for you - see the
[README](README.md).

The detailed steps live in one place, the skill's reference guides, so the manual path and the
automated path never drift apart. They are written to be read directly.

## Prerequisites

- A **Databricks workspace** with Unity Catalog, and an **existing catalog** you can create
  schemas in. Many workspaces cannot create catalogs at all (a Default Storage metastore
  rejects `CREATE CATALOG`), so plan on using one that already exists.
- **Databricks CLI** v0.240+, signed in: `databricks auth login --host <workspace-url> --profile <name>`
- **Terraform 1.5.7** available to the CLI (the pipelines install it themselves)
- Rights to create a **service principal** in the workspace, for CI/CD
- Admin rights on your **repository**: GitHub, or an Azure DevOps project

## Steps

| # | Do | Guide |
|---|---|---|
| 1 | Check access, create the three stage schemas, deploy the bundle, seed production data, create the CI service principal and grant it, register a first model, and link the approval gate | [databricks-foundation.md](.claude/skills/mlops-setup/references/databricks-foundation.md), Phases 0-5 |
| 2 | Configure your platform: credentials, Gate 1 and Gate 2 | [github-actions.md](.claude/skills/mlops-setup/references/github-actions.md) **or** [azure-devops.md](.claude/skills/mlops-setup/references/azure-devops.md) |
| 3 | Verify everything as the service principal | [databricks-foundation.md](.claude/skills/mlops-setup/references/databricks-foundation.md), Phase 7 |
| - | Swap in your own model | [bring-your-own-model.md](.claude/skills/mlops-setup/references/bring-your-own-model.md) |
| - | Something failed | [troubleshooting.md](.claude/skills/mlops-setup/references/troubleshooting.md) |

Check each step before starting the next - several failures here are silent until much later.

## What you configure (and what you don't)

**Nothing in the repository needs editing.**

| Setting | Locally | In CI |
|---|---|---|
| Catalog | `export BUNDLE_VAR_catalog=<your_catalog>` | `DATABRICKS_CATALOG` (GitHub variable / Azure DevOps variable group) |
| Workspace | your CLI profile (`-p <profile>`) | `DATABRICKS_HOST` |
| Credentials | your CLI profile | `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` |

The stage schemas are fixed: `dbdemos_mlops_dev`, `dbdemos_mlops_staging`, `dbdemos_mlops_prod`.

## Optional: monitoring and drift

Notebooks `07_model_monitoring` and `08_drift_detection` are not part of any job; open them by
hand to show Lakehouse Monitoring. They read the batch-inference output, so run
`databricks bundle run churn_batch_inference -t prod` first, then **07 before 08**. Details are
at the end of [databricks-foundation.md](.claude/skills/mlops-setup/references/databricks-foundation.md).
