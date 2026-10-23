# Bring your own model

The repository ships the dbdemos **advanced churn** model. To use your own, keep the
pipeline and the gates and replace the model-specific notebooks. This page is the contract
between your code and the gates - break it and Gate 3 stops working, usually silently.

**Get the churn demo working end to end first**, then swap one notebook at a time and
re-run. When something breaks you then know which change did it.

## What the gates need from your code

| Step | Notebook | Contract |
|---|---|---|
| Train | `02_model_training_hpo_optuna` | Finish with a **FINISHED** MLflow run named **`mlops-hpo-best-run`** in the stage's experiment, with a metric **`test_f1_score`** and the model logged at artifact path **`model`** |
| Register | `03b_from_notebook_to_models_in_uc` | Picks the best `mlops-hpo-best-run` by `test_f1_score` and registers it as `<CATALOG>.<SCHEMA>.advanced_mlops_churn`. **Registration is what triggers Gate 3** - no new version, no gate. It also tries to set `@Challenger`, but skips that if the running identity does not own the model |
| Evaluate | `04a_challenger_validation` | Sets **`@Challenger`** on the new version (reliably - this is the one that counts) and records each check as a version tag. It must **not** set `Approval_Check` or `@Champion` itself - that is what keeps the gate human |
| Approve | `04b_challenger_approval` | Generic. Raises unless the version's `Approval_Check` tag is `approved` (any case), then sets `@Champion` and removes `@Challenger`. **Keep as is** |
| Serve | `06_serve_features_and_model` | Serves the version passed in by the deployment job (the newly approved `@Champion`) |

## What to replace, what to keep

**Replace with your own:**
- `01_feature_engineering` - your features. Keep writing them to the **production** schema
  only; `00-setup` builds source tables only when the stage schema is the shared-data schema,
  and dev and staging read from production.
- `02_model_training_hpo_optuna` - your training. Honour the run name, metric and artifact
  path above, or change `03b` to match.
- `05_batch_inference` - your scoring.
- The checks in `04a` - the current ones are churn-specific: F1 at least the champion's, and a
  churn revenue-gain metric at least the champion's. Keep the pattern: compute, tag, set
  `@Challenger`, and **never auto-approve**.
- The serving configuration in `06` - it publishes churn features to an online store and
  serves them alongside the model.

**Keep:** `00-setup` (catalog and stage handling), `03b` (adjust run name or metric if you
changed them), `04b`, the bundle resources, and both CI/CD pipelines.

## Keeping the training run within MLflow's limits

`02` logs the final model in a **fresh** run rather than the hyperparameter-search run.
`fe.log_model` copies every metric of the run onto the logged model, and a search run full of
trial metrics exceeds MLflow's limit of 1000 metrics per logged model. If your training does
a search, do the same. The Optuna study name is also unique per run, because a fixed name
reloads an earlier study on the next run and fails with `KeyError: 'optuna.study_direction'`.

## Renaming the model

`advanced_mlops_churn` is written into these places, and all must change together:

- `src/02-mlops-advanced/03b_from_notebook_to_models_in_uc.py` (registration)
- `src/02-mlops-advanced/05_batch_inference.py`
- `src/02-mlops-advanced/06_serve_features_and_model.py` (endpoint name and tag)
- `src/_resources/00-setup.py`
- the `model_short_name` variable in `databricks.yml` (read by the deployment job)

Changing only the variable breaks the pipeline: the deployment job would watch a model the
notebooks never register. If the name does not matter to you, keep it.

After a rename, **re-link the deployment job** to the new model (Phase 5 of
[databricks-foundation.md](databricks-foundation.md)) - the link belongs to the registered
model, not the job.

## Check your swap

```bash
databricks bundle deploy -t dev -p <PROFILE>
databricks bundle run churn_training -t dev -p <PROFILE>
```

Then confirm a new version was registered in `dbdemos_mlops_dev` (use the per-version `get`
endpoint - `search` omits aliases and tags). Only registration runs in dev - the deployment job
is linked to the production model - so in dev `challenger` comes from `03b` and appears when
you own the model. The full gate behaviour shows up in production. Once dev registers cleanly,
the CI/CD pipeline carries the change through staging and production unchanged.
