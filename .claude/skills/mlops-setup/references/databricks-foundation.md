# Databricks foundation (both platforms)

The Databricks half of the setup. It is the same whether CI/CD runs on GitHub Actions or
Azure DevOps. Do Phases 0-5 here, then Phase 6 in your platform's file
([github-actions.md](github-actions.md) or [azure-devops.md](azure-devops.md)), then come
back for Phase 7.

Every value in angle brackets (`<CATALOG>`, `<PROFILE>`, ...) comes from the user. Never
guess one, and never echo a service principal secret.

## Phase 0 - Collect settings and check access

```bash
databricks --version                      # need v0.240+
databricks auth profiles                  # find or create the target profile
databricks current-user me -p <PROFILE>    # must return the expected identity
```

You need three things from the user:

| Setting | How to get it |
|---|---|
| CLI profile | `databricks auth login --host <workspace-url> --profile <name>` (interactive - the user runs it) |
| Catalog | Must already exist. `databricks catalogs list -p <PROFILE>` |
| Schemas | Fixed: `dbdemos_mlops_dev`, `dbdemos_mlops_staging`, `dbdemos_mlops_prod`. If any already exist in that catalog for something else, use a different catalog |

**Confirm the catalog is writable before going further**:

```bash
databricks grants get catalog <CATALOG> -p <PROFILE>
```

Look for `ALL_PRIVILEGES`/`MANAGE`, or at least `USE_CATALOG` + `CREATE_SCHEMA`, for the
user's identity (or a group they belong to). If they cannot create schemas, stop and say
so - everything downstream fails otherwise.

> **You usually cannot create a catalog.** Many workspaces (all FEVM sandboxes) use a
> Default Storage metastore, where `CREATE CATALOG` fails with *"Metastore storage root URL
> does not exist"* unless you supply a managed location. Use an existing catalog.
> On a shared workspace, pick a catalog the user actually owns (`ALL_PRIVILEGES`/`MANAGE`)
> so you never write into someone else's namespace. The schema names are not configurable in
> this version: they are set in the bundle targets and in `00-setup`'s shared-data default,
> which no job overrides, so renaming them in one place breaks how dev and staging find the
> production data.

## Phase 1 - Create the three stage schemas

```bash
for S in dbdemos_mlops_dev dbdemos_mlops_staging dbdemos_mlops_prod; do
  databricks schemas create $S <CATALOG> -p <PROFILE>
done
databricks schemas list <CATALOG> -p <PROFILE>     # verify all three
```

## Phase 2 - Deploy the bundle

The catalog is a **bundle variable** - never edit it into a file:

```bash
cd churn-mlops
export BUNDLE_VAR_catalog=<CATALOG>
export DATABRICKS_TF_VERSION=1.5.7

databricks bundle validate -t dev -p <PROFILE>
for T in dev staging prod; do
  databricks bundle deploy -t $T -p <PROFILE>
done
databricks jobs list -p <PROFILE>          # expect 12 jobs: 4 per stage
```

Judge success by the **job count**, not by the output text. Depending on CLI version a
successful deploy prints either `Deployment complete!` or a summary line like
`Resources: 0 created, 0 changed, 0 deleted, 4 unchanged` - both are fine, and grepping
for the former gives false failures.

**Verify the catalog actually resolved** - a deploy *succeeds* with the variable unset,
creating jobs whose model name contains a literal placeholder that only breaks at run
time:

```bash
databricks bundle validate -t prod -o json -p <PROFILE> \
  | python3 -c "import json,sys; [print(p['default']) for j in json.load(sys.stdin)['resources']['jobs'].values() for p in (j.get('parameters') or []) if p['name']=='model_name']"
```

If that prints `<CATALOG>.…` rather than your catalog, `BUNDLE_VAR_catalog` is not set.

> Terraform: if the CLI fails with `openpgp: key expired` it is trying to download
> Terraform. Install 1.5.7 and point at it with `DATABRICKS_TF_EXEC_PATH=/path/to/terraform`.
> An already-installed 1.5.7 works fine (`which terraform`).

## Phase 3 - Seed production data

Production owns the data. This is also what creates the feature/label tables everything
else reads:

```bash
databricks bundle run churn_feature_engineering -t prod -p <PROFILE>
```

Verify the invariant - **prod has the tables, dev and staging have none**:

```bash
for S in prod staging dev; do
  echo "== $S"; databricks tables list <CATALOG> dbdemos_mlops_$S -p <PROFILE> --output json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))"
done
```

Expect roughly 3 tables + the `avg_price_increase` function in prod, and 0 elsewhere.

## Phase 4 - CI service principal

Creating a service principal and minting its secret needs the user's authorisation, and
the secret must never be printed into a transcript. **Ask the user to run these**:

```bash
databricks service-principals create --display-name churn-mlops-ci -p <PROFILE>
databricks service-principal-secrets-proxy create <SP_NUMERIC_ID> -p <PROFILE>
```

Ask them for the **application id** (safe to share) and to keep the secret for Phase 6.

Then apply the permission chain. Each grant unblocks a specific step, and two can only be
applied after the objects exist:

```bash
SP=<APPLICATION_ID>; CAT=<CATALOG>; P=<PROFILE>

# A. catalog - CREATE_SCHEMA is required even though the schemas exist,
#    because every notebook's setup runs CREATE DATABASE IF NOT EXISTS
databricks grants update catalog $CAT -p $P \
  --json "{\"changes\":[{\"principal\":\"$SP\",\"add\":[\"USE_CATALOG\",\"CREATE_SCHEMA\"]}]}"

# B. schemas
for S in dbdemos_mlops_dev dbdemos_mlops_staging dbdemos_mlops_prod; do
  databricks grants update schema $CAT.$S -p $P \
    --json "{\"changes\":[{\"principal\":\"$SP\",\"add\":[\"USE_SCHEMA\",\"SELECT\",\"EXECUTE\",\"CREATE_TABLE\",\"CREATE_FUNCTION\",\"CREATE_MODEL\",\"MODIFY\"]}]}"
done

# C. bundle root, so the service principal can redeploy what a human deployed
OBJ=$(databricks workspace get-status /Workspace/Shared/.bundle/churn-mlops -p $P --output json | python3 -c "import json,sys; print(json.load(sys.stdin)['object_id'])")
databricks permissions update directories $OBJ -p $P \
  --json "{\"access_control_list\":[{\"service_principal_name\":\"$SP\",\"permission_level\":\"CAN_MANAGE\"}]}"

# D. staging/prod jobs - a human-deployed job blocks the service principal
databricks jobs list -p $P --output json | python3 -c "
import json,sys
for j in json.load(sys.stdin):
    n=j['settings']['name']
    if n.startswith('[staging]') or n.startswith('[prod]'): print(j['job_id'])
" | while read JID; do
  databricks permissions update jobs $JID -p $P \
    --json "{\"access_control_list\":[{\"service_principal_name\":\"$SP\",\"permission_level\":\"IS_OWNER\"},{\"user_name\":\"<USER_EMAIL>\",\"permission_level\":\"CAN_MANAGE\"}]}"
done
```

**Model-level grants come after the model exists** (Phase 5) - schema `CREATE_MODEL` does
not allow adding versions to an existing model, and the gate notebooks need `MANAGE` to
set tags and aliases.

## Phase 5 - First model version, then the approval gate

```bash
databricks bundle run churn_training -t prod -p <PROFILE>
```

This runs **two** tasks: `train` logs to MLflow, and `register` creates the Unity Catalog
version. Without the register task nothing ever reaches a gate.

Now the model exists, so finish the permission chain:

```bash
databricks grants update function $CAT.dbdemos_mlops_prod.advanced_mlops_churn -p $P \
  --json "{\"changes\":[{\"principal\":\"$SP\",\"add\":[\"CREATE_MODEL_VERSION\",\"MANAGE\"]}]}"
```

If the training ran as a **human** rather than the service principal, the MLflow
experiment sits in that user's namespace and the service principal cannot read it:

```bash
databricks experiments list-experiments -p $P --output json | python3 -c "
import json,sys
for e in json.load(sys.stdin):
    if 'mlops' in e.get('name','').lower(): print(e['experiment_id'], e['name'])
"
databricks permissions update experiments <EXP_ID> -p $P \
  --json "{\"access_control_list\":[{\"service_principal_name\":\"$SP\",\"permission_level\":\"CAN_MANAGE\"}]}"
```

**Link the deployment job to the model - this is Gate 3:**

```bash
JOB=$(databricks jobs list -p $P --output json | python3 -c "
import json,sys
for j in json.load(sys.stdin):
    if j['settings']['name']=='[prod] churn-deployment-job': print(j['job_id'])
")
M=<CATALOG>.dbdemos_mlops_prod.advanced_mlops_churn
databricks api patch /api/2.0/mlflow/unity-catalog/registered-models/update -p $P \
  --json "{\"name\":\"$M\",\"deployment_job_id\":\"$JOB\"}"
```

Verify with a **fresh read**, not the write's response:

```bash
databricks api get "/api/2.0/mlflow/unity-catalog/registered-models/get?name=$M" -p $P
```

You want `deployment_job_state: CONNECTED`. Note the Unity Catalog API
`/api/2.1/unity-catalog/models/{name}` reports `deployment_job_id: null` even when the
link is good - do not trust it.

> Versions registered **before** the link do not park at the gate. To arm the gate, run
> `churn_training -t prod` once more and let the new version park.


## Phase 7 - Verify the whole thing

Confirm as the **service principal**, since that is what CI uses:

```bash
export DATABRICKS_HOST=<workspace url>
export DATABRICKS_CLIENT_ID=<application id>
export DATABRICKS_CLIENT_SECRET=<secret>   # from the user's environment, never echoed
export BUNDLE_VAR_catalog=<CATALOG>
unset DATABRICKS_TOKEN

databricks current-user me                       # authenticates as the application id
databricks bundle validate -t staging
databricks bundle deploy   -t staging            # exactly what CI runs
databricks bundle run churn_training -t staging  # must reach the register task
```

Then check the gate is armed - the parked version should show `challenger` and its
`Approval_Check` tag should be absent or not `Approved`:

```bash
databricks api get "/api/2.0/mlflow/unity-catalog/model-versions/get?name=$M&version=<N>" -p $P
```

Note the **`search`** endpoint omits aliases and tags - use the per-version `get`, or you
will think they vanished. Aliases read back lowercase (`champion`, `challenger`) even
though the UI capitalises them.

Gate 3 behaves like this, and the middle step **failing is correct**:

```
Evaluation      SUCCESS  -> sets @challenger + validation tags
Approval_Check  FAILED   -> "Model version not approved for deployment"
Deployment      SKIPPED
```

A human then approves in Unity Catalog (model version page -> Approve), which sets
`Approval_Check=Approved` and re-runs the job, promoting to `@champion` and updating the
serving endpoint.

## Optional - monitoring and drift

Notebooks `07_model_monitoring` and `08_drift_detection` are not in any job; open them by
hand. They read `advanced_churn_offline_inference`, so **batch inference must have run in
the target schema first**:

```bash
databricks bundle run churn_batch_inference -t prod -p <PROFILE>
```

Run 07 before 08 - 07 creates the inference table, the baseline table and the monitor;
08 injects synthetic drift and reads the monitor's metrics tables. Both take a while (08
generates 30 days of data and polls the monitor refresh).

