# Churn MLOps on Databricks — GitHub Actions

A reference implementation of production MLOps on Databricks, driven from GitHub. One churn model
is promoted **dev → staging → prod** through pull requests and GitHub Actions, governed by **three
human approval gates**:

1. **Code review** — a pull request into `main` must be reviewed and approved before it merges.
2. **Pre-production release** — after the change is validated in staging, a human approves the
   promotion to production.
3. **Model approval** — in Unity Catalog, a human approves the trained model before it is served.

Built on the **deploy-code** pattern: one codebase, promoted across environments; each stage is an
isolated schema. Data is owned by production and read by dev/staging (no copies). Model promotion
and serving are governed by an MLflow 3 **deployment job**. All CI/CD runs as a Databricks service
principal.

```
 branch feature/*  →  edit  →  open a Pull Request into main
        │
   ┌────▼─────────────────────────────────────────────────────┐
   │ GATE 1 — Code review                                      │
   │   churn-ci validates the change (deploys to staging);     │
   │   a reviewer approves; the PR merges.                      │
   └────┬──────────────────────────────────────────────────────┘
        │ merge to main triggers churn-cd (one run):
        │   • Staging  — deploy, train, register a model (end-to-end check)
        │   • Promote  — advance the `release` pointer
   ┌────▼─────────────────────────────────────────────────────┐
   │ GATE 2 — Pre-production release                           │
   │   the pipeline pauses; a human approves promotion to prod │
   └────┬──────────────────────────────────────────────────────┘
        │   • Prod     — deploy, train, register a new prod model version
        │                (parks awaiting model approval)
   ┌────▼─────────────────────────────────────────────────────┐
   │ GATE 3 — Model approval (Unity Catalog)                   │
   │   a data scientist approves the version → it becomes       │
   │   Champion → the serving endpoint updates                 │
   └───────────────────────────────────────────────────────────┘
```

---

> **Note on CI status.** The `churn-ci` / `churn-cd` workflows deploy to a real Databricks
> workspace, so they run green only once you have configured the three Actions secrets described
> in [SETUP.md](SETUP.md) for your own workspace. A failing check on a fresh clone means no
> workspace is configured yet, not a problem with the code.

## Repository layout
```
.github/workflows/
  churn-ci.yml    # on PR to main: validate + deploy to staging (Gate 1 status check)
  churn-cd.yml    # on merge to main: staging → (Gate 2 approval) → prod
churn-mlops/                       # the Databricks Asset Bundle
  databricks.yml                   # dev / staging / prod targets (one schema per stage)
  resources/churn_jobs.yml         # feature engineering, training (+register), batch inference
  resources/deployment_job.yml     # MLflow 3 deployment job (the model-approval gate)
  src/_resources/00-setup.py       # shared-data setup (production owns the data)
  src/02-mlops-advanced/           # the churn ML notebooks (feature eng, training, validation,
                                   #   approval, serving)
```

---

## The daily loop

1. **Branch & edit.** From the Databricks Git folder (or locally), create a `feature/*` branch and
   make your change — e.g. a model hyperparameter or a job configuration.
2. **Open a pull request** into `main`.
3. **Gate 1 — review & merge.** GitHub Actions runs `churn-ci`, which validates the bundle and
   deploys it to staging. Once the check is green and a reviewer approves, merge the PR.
4. **Automated promotion.** Merging triggers `churn-cd`: it deploys to staging, trains and registers
   a model there (the end-to-end check), then advances the `release` pointer.
5. **Gate 2 — approve the release.** The pipeline pauses before production and waits for a human to
   approve the deployment in GitHub. On approval, it deploys to production, trains, and registers a
   new production model version — which parks awaiting model approval.
6. **Gate 3 — approve the model.** In Unity Catalog, open the new model version and click **Approve**.
   It becomes `@Champion` and the serving endpoint updates to it.

**Three human actions:** approve & merge the PR · approve the pre-production release · approve the model.

---

## CI/CD

Two GitHub Actions workflows under `.github/workflows/`. Each installs the Databricks CLI and
authenticates as the CI service principal (OAuth machine-to-machine, from the repo's Actions secrets).

| Workflow | Trigger | What it does |
|---|---|---|
| `churn-ci.yml` | Pull request into `main` | Validates the bundle and deploys it to **staging** (`bundle validate` + `bundle deploy -t staging`). This is the required status check for Gate 1 — code can't merge unless it is deployable. |
| `churn-cd.yml` | Merge to `main` | One run, three stages: **Staging** (deploy → train → register a model = the end-to-end check) → **Promote** (advance the `release` pointer) → **Prod** (deploy → train → register a new production model version, which parks for model approval). The **Prod** stage is protected by a GitHub Environment approval — **Gate 2**. |

**Where the gates live**
- **Gate 1 — the pull request.** Branch protection on `main` requires the `churn-ci` check to pass
  **and** a reviewer to approve before the PR can merge.
- **Gate 2 — the pre-production release.** The `churn-cd` prod stage targets a protected GitHub
  Environment (`prod`); the run pauses and a designated reviewer approves the promotion.
- **Gate 3 — the model.** The production model version parks in Unity Catalog until a human clicks
  **Approve**; only then does the deployment job promote it to `@Champion` and update the serving
  endpoint.

**Design notes**
- **Test what you ship.** The exact commit that passes the staging end-to-end check is the commit
  deployed to production, in the same pipeline run.
- **`release` is an audit pointer**, not a trigger — it records what production is running. Production
  is deployed within the `churn-cd` run itself, so there is a single pipeline and no duplicate runs.
- **Environment separation.** dev, staging, and prod are isolated schemas in one catalog; production
  owns the data and dev/staging read it, so there are no data copies to drift.

---

## Setup (once per workspace)

### The quick path — use the setup skill

If you work with Claude Code, this repository ships a skill that takes you from this clone
to a working pipeline:

```
/mlops-e2e-setup
```

It checks your CLI and catalog access, creates the three stage schemas, deploys the bundle
to dev/staging/prod, seeds production data, walks you through the CI service principal and
its permission chain, registers a first model version, links the approval gate, and tells
you exactly which GitHub secrets and variable to set. It verifies each phase before moving
on, and stops to ask you for the few things it cannot safely do itself — creating a service
principal and minting its secret.

The skill lives in [`.claude/skills/mlops-e2e-setup/`](.claude/skills/mlops-e2e-setup/) and
is worth reading even if you set things up by hand: it records the failure modes that cost
us the most time.

### Or by hand

**Nothing in the repository needs editing.** The catalog is a bundle variable and the
workspace URL comes from your environment, so configuration is:

| Setting | Local | In CI |
|---|---|---|
| Catalog | `export BUNDLE_VAR_catalog=<your_catalog>` | repository **variable** `DATABRICKS_CATALOG` |
| Workspace | your CLI profile (`-p <profile>`) | secret `DATABRICKS_HOST` |
| Credentials | your CLI profile | secrets `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` |

Create three schemas in your catalog — `dbdemos_mlops_dev`, `dbdemos_mlops_staging`,
`dbdemos_mlops_prod`. Production owns the data; dev and staging read from it.

Then:

1. **GitHub secrets and variable** — `Settings → Secrets and variables → Actions`. Three
   secrets as above, plus the variable `DATABRICKS_CATALOG`. The workflows fail fast with a
   clear message if the catalog is missing.
2. **Branch protection on `main` (Gate 1)** — require a pull request with **1** approving
   review and the **`validate`** status check. Create `main` and `release`.
3. **Environment `prod` (Gate 2)** — `Settings → Environments → New environment → prod`,
   add a **required reviewer**. The production stage targets it, so promotion pauses.
4. **Databricks side** — deploy the bundle per target, grant the CI service principal, and
   link the MLflow deployment job to the production model so new versions park for approval
   (Gate 3).

Full step-by-step, including every permission grant and a troubleshooting section, is in
**[SETUP.md](SETUP.md)**.

> **Gates 1 and 2 need a public repository** on GitHub Free. Branch protection and
> environment required-reviewers are both rejected on a private repo on that plan — and a
> private repo will happily create the `prod` environment without pausing, which quietly
> removes Gate 2. Check this before relying on the gates.

---

## Notes

- **Model governance is deliberate.** Training in staging and prod **registers** a model version;
  production versions do not serve until approved (Gate 3). Approval promotes the version to
  `@Champion`, retires the prior `@Challenger` marker, and updates the serving endpoint.
- **Solo demos.** GitHub does not allow a pull-request author to approve their own PR. With a second
  reviewer, Gate 1 is satisfied normally; running solo, a repository admin can merge directly. The
  automated `validate` check is always enforced either way.
- **Setup guide.** To stand this up in your own workspace — prerequisites, the service-principal
  permission chain, the deployment-job wiring, and troubleshooting — see **[SETUP.md](SETUP.md)**.
