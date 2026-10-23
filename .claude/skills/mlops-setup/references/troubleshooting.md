# Troubleshooting and known limitations

## Where this has been proven

| Part | Status |
|---|---|
| Databricks foundation (Phases 0-5, 7) | Run end to end on two unrelated workspaces: an Azure FEVM sandbox, and a shared AWS workspace using an existing catalog. The CI service principal and its full permission chain were exercised on the first |
| GitHub Actions (Phase 6) | A full pull-request-to-production pass, all three gates, completed on 2026-08-01. **Not re-run since** two later changes: the catalog becoming a variable, and `promote` moving after the production deploy |
| Azure DevOps (Phase 6) | **Pipelines written, not yet run.** The `az` commands are checked against Microsoft's reference; the pipelines themselves have not completed a run |

In every completed run: 12 jobs deployed, production held the feature/label tables while dev
and staging held none, the model registered, the deployment job reported `CONNECTED`, and a
newly registered version parked with `Approval_Check` failing on
*"Model version not approved for deployment"*.

If a run diverges from that, treat it as a real difference worth understanding rather than
something to work around.

## When something fails

| Symptom | Cause |
|---|---|
| `PERMISSION_DENIED` naming an object | A missing grant from Phase 4. The message names the object - grant that privilege |
| Model never appears / nothing to approve | The training job needs its `register` task (notebook 03b); training alone only logs to MLflow |
| Jobs created with `<CATALOG>` in the name | `BUNDLE_VAR_catalog` was unset during deploy - re-export and redeploy |
| `Metastore storage root URL does not exist` | Something tried `CREATE CATALOG` on a Default Storage metastore - point at an existing catalog |
| Deployment job fails at the serving step | Serverless serving may need a budget policy the workspace lacks; the notebook treats it as non-fatal so the model still promotes |
| `KeyError: 'optuna.study_direction'` | A repeat run reloading a previous study - the training notebook uses a unique study name per run; keep that |
| Endpoint does not update after approval | Same budget-policy grant. The promotion still happened; check the alias |
| Pipeline stops at **Check configuration** naming a variable | It is missing from the GitHub secrets/variable or the Azure DevOps `mlops-databricks` group. An undefined Azure DevOps variable reads as the literal text `$(NAME)`, which the check treats as missing |
| Azure DevOps run waits on *"needs permission to access a resource"* | First use of the variable group or Environment. Click **Permit** once |
| Production deployed without pausing | The approval is missing. GitHub: private repo on Free, or no reviewer on `prod`. Azure DevOps: the `prod` Environment was auto-created by the first run with no approval - add one in *Approvals and checks* |
| Azure DevOps **Promote** fails with `TF401027` | The project's Build Service lacks **Contribute** on the repository, or `release` has a branch policy. Fix the permission; never force-push |
| CI cannot reach the workspace | The workspace uses IP access lists and the hosted runners/agents are outside them. Use self-hosted runners/agents |
| Deployment job fails at the serving step with a missing table, after `@Champion` already moved | A deployment-job task is not receiving `stage_db`, so `00-setup` falls back to the wrong schema. Every task in `resources/deployment_job.yml` must pass `catalog` and `stage_db` |
| No branch, commit or push controls in the Databricks workspace | The folder is a plain copy of the files, not a Git folder (it can even contain `.git`). Delete it and clone through **Workspace -> Create -> Git folder** (or `databricks repos create`) |

## Known limitations

- **One workspace only.** Stages are separated by schema inside one catalog. A separate
  workspace per stage (each with its own host and service principal) is not supported yet.
  Do not improvise it; tell the user it is out of scope for this version.
- **The serving endpoint is named after whoever runs the deployment job.** Notebook 06 builds
  the name as `advanced_mlops_churn_` plus the letters of the running identity. When the CI
  service principal runs it, that is the letters of its UUID, so a new or rotated service
  principal creates a **new** endpoint and the old one is left behind. Anyone who runs the job
  by hand gets yet another. Expect this, and tell the user before they rotate credentials.
  The online feature store name (`00-setup`) follows the same per-user convention.
- **The model name is fixed.** `advanced_mlops_churn` is written into five notebooks. The
  `model_short_name` bundle variable only feeds the deployment job, so changing the variable
  alone breaks the pipeline. See [bring-your-own-model.md](bring-your-own-model.md).
- **Gates 1 and 2 on GitHub need a public repository** on the Free plan; see
  [github-actions.md](github-actions.md).
