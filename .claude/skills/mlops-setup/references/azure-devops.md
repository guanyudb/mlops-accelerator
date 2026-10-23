# Phase 6 - Azure DevOps

Wire an Azure Repos repository and Azure Pipelines to the Databricks foundation. Gate 1 and
Gate 2 live here; Gate 3 is already armed on the Databricks side.

> **Status: written, not yet run end to end.** These pipelines mirror the GitHub Actions ones,
> which have been validated, but this exact Azure DevOps setup has not completed a full run.
> Treat the user's first run as the test, and watch the points marked **check** below.

Unlike GitHub Free, branch policies and Environment approvals work on **every** Azure DevOps
tier and on private repositories, so there is no visibility caveat here.

## Before you start

The user needs the Azure CLI with the Azure DevOps extension, signed in (interactive - the
user runs it):

```bash
az extension add --name azure-devops
az login
az devops configure --defaults organization=https://dev.azure.com/<ORG> project=<PROJECT>
```

## Get the code into Azure Repos

If the user cloned from GitHub, create the repository and push. Ask before pushing.

```bash
az repos create --name <REPO>
git remote add azure https://dev.azure.com/<ORG>/<PROJECT>/_git/<REPO>
git push azure main
git push azure main:release        # `release` records what production runs
```

The `.github/` folder is ignored by Azure DevOps; the pipelines live in `azure-pipelines/`.

## The variable group `mlops-databricks`

The pipelines read four values from it. The names must match exactly.

```bash
az pipelines variable-group create --name mlops-databricks --authorize false \
  --variables DATABRICKS_HOST=<WORKSPACE_URL> \
              DATABRICKS_CLIENT_ID=<APPLICATION_ID> \
              DATABRICKS_CATALOG=<CATALOG>
GROUP_ID=$(az pipelines variable-group list --group-name mlops-databricks --query "[0].id" -o tsv)
```

**The user adds the secret.** With no `--value`, the command prompts on standard input (or
reads `AZURE_DEVOPS_EXT_PIPELINE_VAR_DATABRICKS_CLIENT_SECRET` if set), so the value never
appears in a command line or transcript:

```bash
az pipelines variable-group variable create --group-id $GROUP_ID \
  --name DATABRICKS_CLIENT_SECRET --secret true
```

If any of the four is missing, every pipeline stops at **Check configuration** naming the
missing one. (An undefined Azure DevOps variable is not empty - it is left as the literal
text `$(NAME)` - and the check treats that as missing.)

## Create the two pipelines

```bash
az pipelines create --name churn-ci --repository <REPO> --repository-type tfsgit \
  --branch main --yml-path azure-pipelines/churn-ci.yml --skip-first-run true
az pipelines create --name churn-cd --repository <REPO> --repository-type tfsgit \
  --branch main --yml-path azure-pipelines/churn-cd.yml --skip-first-run true
```

**check:** the first run of each pauses with *"This pipeline needs permission to access a
resource"* for the variable group (and, for `churn-cd`, the environment). Click **Permit**
once. That is safer than `--authorize true`, which would let every pipeline in the project
use the service principal's credentials.

## Gate 2 - the `prod` Environment, created BEFORE the first `churn-cd` run

A deployment job that names an Environment that does not exist **creates it with no
approval**, and production then deploys without pausing - Gate 2 silently disappears. So
create it first, in the UI:

1. **Pipelines -> Environments -> New environment**, name `prod`, resource **None**.
2. On `prod`: **... -> Approvals and checks -> + -> Approvals**, add the approver(s).

**check:** the `prod` Environment's *Approvals and checks* tab lists an **Approval**. If it is
empty, Gate 2 is not enforced.

## Gate 1 - branch policies on `main`

```bash
REPO_ID=$(az repos show --repository <REPO> --query id -o tsv)
CI_ID=$(az pipelines show --name churn-ci --query id -o tsv)

az repos policy approver-count create --repository-id $REPO_ID --branch main \
  --blocking true --enabled true --minimum-approver-count 1 \
  --creator-vote-counts false --allow-downvotes false --reset-on-source-push true

az repos policy build create --repository-id $REPO_ID --branch main \
  --blocking true --enabled true --build-definition-id $CI_ID --display-name validate \
  --manual-queue-only false --queue-on-source-update-only false --valid-duration 0
```

With `--creator-vote-counts false` nobody can approve their own pull request, so a solo user
needs a second reviewer. Do **not** weaken the policy to get past it; a project administrator
can be granted *Bypass policies when completing pull requests* if that is genuinely needed.

## Let the pipeline move `release`

The **Promote** stage pushes `release` forward using the build service identity. In
**Project settings -> Repositories -> <REPO> -> Security**, give
**`<PROJECT> Build Service (<ORG>)`** the **Contribute** permission. Put **no** branch policy
on `release` - it is a pointer, not a gate, and a policy there blocks the push.

**check:** the first Promote run either succeeds or fails with `TF401027` (missing
Contribute) - the fix is the permission above, not a force push.

## Network

Microsoft-hosted agents connect from Azure's public IP ranges. If the workspace uses IP
access lists, the pipelines cannot reach it; use a self-hosted agent pool and change `pool:`
in both pipelines.

## How the pipeline uses this

```
pull request -> main     churn-ci: validate + deploy to staging      (Gate 1: policies)
merge to main            churn-cd: DeployStaging -> train + register in staging
                                   DeployProd    -> waits for the prod Environment approval
                                                    (Gate 2), then deploy + train + register
                                   Promote       -> fast-forward release to this commit
new prod model version   parks until approved in Unity Catalog                   (Gate 3)
```

Then return to Phase 7 in [databricks-foundation.md](databricks-foundation.md).
