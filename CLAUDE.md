# MLOps Accelerator - notes for Claude

This repository is a reference implementation of governed MLOps on Databricks: one
Databricks Asset Bundle promoted dev -> staging -> prod, with three human approval gates,
on **GitHub Actions or Azure DevOps**.

## If someone wants to set it up

Use the **`mlops-setup`** skill (`.claude/skills/mlops-setup/`). It asks which CI/CD
platform, whether to run the included demo or their own model, and which workspace and
catalog, then walks the setup phase by phase with a check after each. Start there rather
than improvising from the code.

## Layout

| Path | What |
|---|---|
| `churn-mlops/` | The bundle: `databricks.yml`, job definitions in `resources/`, notebooks in `src/` (dbdemos advanced churn, with the fixes needed to run it under CI) |
| `.github/workflows/` | GitHub Actions: `churn-ci.yml` (pull requests) and `churn-cd.yml` (merge to `main`) |
| `azure-pipelines/` | Azure DevOps: the same two pipelines, plus a shared steps template |
| `.claude/skills/mlops-setup/` | The setup skill and its references (also readable as plain docs) |
| `SETUP.md` | Where a human starts when setting up by hand |

Each CI system ignores the other's folder, so one copy of the repo serves both.

## Things that are easy to get wrong here

- **The catalog is a bundle variable**, never written into files: `BUNDLE_VAR_catalog`
  locally, the `DATABRICKS_CATALOG` variable in CI. A deploy *succeeds* with it unset and
  produces jobs that fail later, which is why both platforms check it first.
- **Gate 3 depends on registration.** The training job has two tasks, `train` then
  `register`; only a newly registered Unity Catalog version reaches the approval gate.
- **A failing `Approval_Check` task is correct** - that is the gate holding a model until a
  human approves it.
- **Schema names are fixed** (`dbdemos_mlops_dev`, `_staging`, `_prod`) and stages are
  schemas in one workspace. Separate workspaces per stage are not supported yet.
- **Never print a service principal secret**, and never weaken a branch policy, branch
  protection or Environment approval to get past a gate.
