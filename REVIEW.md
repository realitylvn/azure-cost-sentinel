# REVIEW.md — Build Log & Learning Notes

Personal study companion to this project. Unlike README.md (public/recruiter-facing),
this file tracks *why* each decision was made and logs every `az`/`azd` command as it
runs, so the reasoning doesn't get reconstructed from memory after the fact.

## Why this approach

- **Stateless by default**: the Function queries the Cost Management API fresh on
  every run instead of maintaining a database. There's nothing to migrate, back up,
  or get out of sync — the only failure mode is "the API call didn't return data,"
  which is already a case we have to handle.
- **The one deliberate exception (dedupe-state blob)**: without *some* memory of
  "did we already alert on this," a sustained anomaly (e.g., a runaway resource left
  on for a week) would re-alert every single day. A single timestamp in blob storage
  is the smallest possible piece of state that solves that, without becoming a
  general-purpose datastore.
- **`azd init -m` (minimal) over hand-rolled `infra/`**: starting from `azd`'s minimal
  scaffold gives a project structure (`azure.yaml`, environment config under `.azure/`)
  that already matches `azd`'s conventions for `provision`/`deploy`/`pipeline config`.
  Hand-rolling the same thing risks drifting from those conventions in ways that only
  surface later, when `azd` commands expect files in specific places.
- **Cost Management Reader over Contributor/Owner (planned for Stage 2)**: the
  Function only ever *reads* cost data and writes to its own storage account — it
  never needs to create, modify, or delete other resources. Scoping the identity's
  role to Reader, and to the resource group rather than the subscription, means a
  bug or leaked credential in this Function can't be used to touch anything else in
  the subscription.

- **Scheduled Query (Log) Alert instead of a direct Action Group call**: the spec's
  "sends a notification via Action Group" sounds like the Function should call the
  Action Group directly, but the Action Group trigger APIs need Monitor-related RBAC
  on the caller — which would mean giving the Function's identity more than the
  single Cost Management Reader role the spec insists on. Instead, the Function just
  logs a plain-English `"AnomalyDetected: ..."` trace to Application Insights (that
  only needs the connection string, no RBAC at all), and a `scheduledQueryRules`
  Log Alert watches for that trace pattern and fires the Action Group. Same outcome
  (email on anomaly, zero extra services), but the Function's identity stays exactly
  as scoped as the spec describes.
- **Host storage via account key, not identity-based connection**: Azure Functions'
  own internal storage (`AzureWebJobsStorage`, used for triggers/leases, separate
  from the dedupe-state blob) can be wired with either a connection string or an
  identity-based connection. Identity-based would need 2-3 more RBAC roles
  (Storage Blob/Queue/Table Data Contributor) on the Function's identity. Since the
  spec explicitly enumerates exactly one role assignment (Cost Management Reader),
  I used the account-key connection string instead — it's an app setting (encrypted
  at rest, not a secret in source), and it's the default pattern in `azd`'s own
  Functions templates. Worth revisiting later if you want to hardcode zero secrets
  anywhere, but it keeps this stage matching the spec as written.

## Platform quirks hit along the way

- **Y1 (Consumption plan) quota is its own family, separate from Compute VM quota.**
  The first `azd provision --preview` failed preflight with
  `SubscriptionIsOverQuotaForSku`, even though `az vm list-usage` showed healthy
  Compute quota (10 vCPUs available) in the same region. That's because the
  Function App Consumption plan's underlying compute draws from an **App Service**
  quota family (`Microsoft.Web`), tracked completely separately from `Microsoft.Compute`
  VM quota — checking one tells you nothing about the other. Brand-new subscriptions
  commonly start at 0 for this specific quota until requested via Portal → Quotas →
  provider "App Service" (not "Compute"). This one is genuinely easy to blank on,
  since most AZ-104 material talks about VM quota and doesn't call out that Functions'
  Consumption plan is gated by a different bucket entirely.
- **This particular quota request needs a support engineer**, rather than being
  auto-approved instantly — submitted for Y1 in East US 2, not zone-redundant, new
  limit 10. Pick back up here once it clears.
- **Zone redundancy isn't on the table for this SKU anyway.** Zone redundancy spreads
  instances across multiple physical datacenters in a region so the app survives one
  zone going down — a production high-availability feature. The Consumption (Y1)
  plan doesn't support it at all; it's a Premium-plan-only capability. So "Not Zone
  Redundant" in the quota request isn't a compromise, it's just accurate to what Y1
  actually is — and this tool (a single-instance daily cost check against its own
  subscription) has no availability requirement that would justify Premium anyway:
  if the Function misses a run during a rare zone outage, nothing breaks, it just
  checks again on the next schedule.

## Naming & tagging correction (pre-flight, before anything was provisioned)

The Bicep was originally drafted using azd's default `dev` environment name and
resource names built from an opaque `uniqueString()` token alone (`plan-vsgvle7c2q6pe`,
`func-vsgvle7c2q6pe`, etc.). That works, but it's a governance problem the moment a
second Azure project shares this subscription: every resource group would be named
generically, nothing in the portal would say which project a resource belongs to, and
there'd be no way to query "everything belonging to this portfolio" across projects.
This is exactly what Microsoft's Cloud Adoption Framework naming guidance exists to
prevent — `<type>-<project-slug>-<environment>` makes every resource
self-describing, and a shared `portfolio`/`project`/`environment` tag set makes the
whole portfolio queryable later (the planned Ops Dashboard project depends on this).

Caught and fixed before `azd provision` ever ran, so this was a rename, not a
migration:
- azd environment renamed from `dev` to `cost-sentinel-dev` (`azd env new`, values
  copied over, old `dev` env left in place for Jonathan to remove manually).
- Resource names in `resources.bicep` changed from `<type>-${resourceToken}` to
  `<type>-${environmentName}`, so names now read `rg-cost-sentinel-dev`,
  `plan-cost-sentinel-dev`, `log-cost-sentinel-dev`, etc. Only the storage account and
  Function App keep a short uniqueness suffix appended, since those two have globally
  -unique naming requirements the rest of these resource types don't.
- Added `portfolio`, `project`, and `environment` tags (in addition to azd's own
  `azd-env-name`) to every taggable resource. Two resources — `Microsoft.Consumption/budgets`
  and the RBAC role assignment — have no `tags` property in their ARM schema at all
  (confirmed by an actual failed build attempt with `tags:` added, not assumed), so
  naming is the only convention signal those two can carry.

## Provision attempt #1 — partial failure, real bug found

`azd provision` ran for real. 7 resources came up clean (resource group, storage
account, Log Analytics workspace, Application Insights, App Service plan, Function
App, Action Group), then failed creating the anomaly alert rule:

```
BadRequest: 'where' operator: Failed to resolve table or column expression named 'traces'.
```

**Root cause**: the alert's `scopes` pointed at the Log Analytics workspace resource
directly. For workspace-based Application Insights, the raw workspace stores
telemetry in `App*`-prefixed tables (`AppTraces`, PascalCase columns) — the friendly
classic table names (`traces`, camelCase `message`) only resolve when a log alert's
scope is the **Application Insights resource itself**, not the workspace underneath
it. This is a real, easy-to-hit distinction between "Application Insights" and "the
Log Analytics workspace behind it" that AZ-104 tends to gloss over. Fixed by pointing
`scopes` at `appInsights.id` instead of `logAnalytics.id` — no query rewrite needed.
Role assignment and Budget hadn't been created yet when the deployment stopped, so
`azd provision` should pick up cleanly on the next run (idempotent — already-created
resources are left alone).

## Stage 3 — Function code

- **Subscription ID passed as an app setting, not discovered at runtime**
  *(revised — see "Deploy #2" below for why the original runtime-discovery
  approach was dropped)*: `resources.bicep` wires `AZURE_SUBSCRIPTION_ID` into the
  Function App's settings from `subscription().subscriptionId`. The managed
  identity only holds Cost Management Reader on this one subscription, so there is
  nothing to "discover" — and reading it back via `SubscriptionClient` meant
  pulling the entire `azure-mgmt-resource` SDK for a single string. The original
  reasoning ("avoid an infra redeploy") didn't hold up: the value was already in
  the azd environment, and `azd provision` re-runs idempotently anyway.
- **Sampling disabled in `host.json`**: Application Insights sampling is off
  entirely. The one thing the whole alerting design depends on is the single daily
  `AnomalyDetected` trace actually arriving - adaptive sampling could silently drop
  it, and there would be no symptom until an alert quietly failed to fire.
- Not deployed yet - this is the Stage 3 checkpoint (code written, before `azd deploy`).

## Deploy #1 — looked successful, wasn't

`azd deploy` reported success (33s, endpoint published), but `az functionapp
function list` came back empty - zero functions registered, even though the app's
`state` was `Running`. That distinction matters: "the App Service resource is up"
and "the Functions host successfully indexed your code" are different things, and
only the second one means anything actually works.

**Root cause**: no `SCM_DO_BUILD_DURING_DEPLOYMENT` app setting. For a Python
Function App on Linux, a zip deploy without that setting skips Oryx entirely - the
source lands, but `pip install -r requirements.txt` never runs. The Python worker
then can't import `azure.mgmt.costmanagement` etc., fails to load the function, and
reports nothing to index. No error surfaced anywhere in `azd deploy`'s own output;
the only way to catch it was checking the function list directly afterward - "deploy
succeeded" and "the app actually works" are not the same claim, and this is the
concrete example of why that gap matters enough to verify instead of assume.

Fixed by adding `SCM_DO_BUILD_DURING_DEPLOYMENT: "true"` to `resources.bicep`.

## Deploy #2 — build ran, still zero functions: the actual root cause

After `azd provision` (SCM setting applied) and `azd deploy`, Oryx *did* run a
remote build this time — and `az functionapp function list` was *still* empty.
Same surface symptom, different cause underneath.

**Root cause**: `function/requirements.txt` pinned nothing. Oryx installs whatever
is latest at build time, and `azure-mgmt-resource` had moved to **26.0.0**, a
release that split the mega-package into per-service distributions.
`SubscriptionClient` no longer lives at `azure.mgmt.resource` — it moved to a
separate `azure-mgmt-resource-subscriptions` package (`azure.mgmt.resource.subscriptions`).
So `from azure.mgmt.resource import SubscriptionClient` raised `ImportError` at
module load. The Python v2 model indexes functions by *importing* `function_app.py`;
when that import throws, the worker registers zero functions and the host still
reports `state: Running` with no error surfaced anywhere in `azd`'s output. The
only way to see it was `curl .../admin/functions` returning `[]` and reproducing
the import locally in a clean venv.

This is the same "deployed ≠ working" gap as Deploy #1, one layer deeper: Deploy #1
was "deps never installed," Deploy #2 was "deps installed, but a newer major
version broke the API." Both are invisible to `azd deploy`'s success message.

**Fixes** (committed together):
1. `requirements.txt` — every dependency pinned with `==` to the versions actually
   tested, so a remote build is reproducible and a future SDK major bump can't
   silently break a deploy.
2. Dropped `azure-mgmt-resource` entirely. The Function never used resource-
   management APIs — only `SubscriptionClient`, only to read back an ID it already
   operates within. Replaced with an `AZURE_SUBSCRIPTION_ID` app setting wired in
   `resources.bicep` from `subscription().subscriptionId`. Smaller cold start,
   fewer transitive packages, one less thing that can break on `pip install`.
3. Verified locally before redeploying: clean venv + pinned `requirements.txt`,
   `app.get_functions()` returns `['cost_anomaly_check']` — the exact operation
   the worker indexer performs.

RBAC unchanged — the identity still holds only Cost Management Reader on the RG.

### Verified working (this time for real)

`azd provision` (app setting landed) → `azd deploy` → the Function host's own logs
in the Log Analytics workspace tell the whole story:

- **Before**: `AppExceptions` at 03:01 / 03:16 / 03:57 —
  `ImportError: cannot import name 'SubscriptionClient'` → `Worker failed to index
  functions` → `0 functions loaded`. The platform had been logging the exact root
  cause the whole time; `azd` just never surfaced it.
- **After** (04:11): `1 functions loaded` → `Found: Host.Functions.cost_anomaly_check`
  → `The next 5 occurrences of 'cost_anomaly_check' (Cron: '0 0 8 * * *'):
  09/02/2026 08:00:00Z …`
- **Manual invoke** exercised the full chain: `ManagedIdentityCredential` acquired a
  token (200) → `POST …/subscriptions/<SUBSCRIPTION_ID>/providers/Microsoft.CostManagement/query`
  (subscription ID from the new app setting) → `429 Too many requests` (triggered it
  a few times in quick succession — the Cost Management API rate-limits aggressively)
  → caught by the `except AzureError` path → `skipping this run` → `Executed
  (Succeeded)`. The 429 handling is the design working, not a bug.

### Two debugging gotchas worth keeping

- **`az functionapp function list` lags.** It reads an ARM cache that can stay empty
  for many minutes after the runtime has already indexed the function. The
  authoritative check is the runtime admin API:
  `curl -H "x-functions-key: <masterKey>" https://<app>.azurewebsites.net/admin/functions`.
- **`az monitor app-insights query` returned nothing while the data was right
  there.** For a workspace-based Application Insights, query the Log Analytics
  workspace directly instead — `az monitor log-analytics query -w <customerId>`,
  table `AppTraces` / `AppExceptions` (PascalCase columns). That's where the
  `ImportError` and the whole host startup log actually lived.
- **Kudu is mostly disabled on Linux Consumption.** `/api/command`, `/api/vfs`,
  and the log stream all return nothing — there's no persistent SCM container.
  `/api/deployments` works; everything else has to come from the runtime admin
  API or Log Analytics.

## Stage 4 — verification & finishing

### Testing the alert path when the subscription never actually spikes

Real spend on this subscription is ~$0.19/day — comfortably under the
`MINIMUM_BASELINE_USD = 1.0` guard, so the Function will *always* take the
"trailing average near zero, skipping" branch and never emit `AnomalyDetected` on
its own. That's correct behaviour (a percentage delta on pennies is noise), but it
means the anomaly → alert → email path can't be tested by waiting. Split it in two:

- **Action Group email delivery** — `az monitor action-group test-notifications
  create` with an explicit email receiver. Azure's built-in test; returned
  `MechanismType: Email, Status: Succeeded`. Confirms the Action Group and the
  address work without any alert rule involved.
- **Alert rule (query + scope)** — POSTed a synthetic telemetry item straight to
  the App Insights ingestion endpoint (`.../v2.1/track`, `MessageData`,
  `message: "AnomalyDetected: 999% above 7-day average (SYNTHETIC…)"`). Only needs
  the instrumentation key, no RBAC. Trace at 04:39 UTC landed in `AppTraces`; the
  `scheduledQueryRules` rule fired at 04:49 UTC (`Fired:Sev3 … on appi-cost-sentinel-dev`)
  and the Action Group email arrived. `autoMitigate: true` clears it once the trace
  ages out of the 1-hour window. Full path — trace → Log Analytics → alert rule →
  Action Group → inbox — confirmed end to end.

Together that covers the whole chain the Function depends on, without deploying any
test-only code into `function_app.py`.

### Removed the stale `dev` azd environment

`azd env remove dev --force`. The original `dev` environment (from `azd init`)
never completed a provision — the first attempt died at the Y1 quota preflight, and
everything was renamed to `cost-sentinel-dev` before any resource was created. So
there was nothing in Azure to clean up; `azd env remove` only deletes the local
`.azure/dev/` folder (which is gitignored anyway). This is why it never appeared in
the portal — an azd environment is local CLI state, not an Azure resource.

### CI: validation now, OIDC deploy pipeline deferred

`.github/workflows/validate.yml` runs on every PR/push: `az bicep build` plus a
job that installs the pinned requirements and asserts `function_app.app.get_functions()`
returns exactly `['cost_anomaly_check']`. Those are precisely the two failures that
cost two deploy cycles here, and both are invisible to `azd deploy`'s exit code —
so they're worth a cheap gate that runs without any cloud credentials.

The fuller move — `azd pipeline config` to provision an Entra app registration,
a federated credential trusting this GitHub repo, and a deploy-on-push workflow —
is deliberately deferred. It's the stronger AZ-104 story, but it means a
deploy-capable identity with a standing trust relationship to a *public* repo, and
an Entra object to keep track of, for a project that one person deploys by hand in
seconds. Documented here so the reasoning is on record; revisit if the deploy
cadence ever justifies it.

### Polish: pure decision function + unit tests + configurable baseline

Two changes to make this portfolio-grade rather than just working:

- **`evaluate_anomaly` extracted as a pure function.** The timer entrypoint was
  one function doing cost query, trailing-average math, threshold + cooldown
  decisions, blob state, and logging all inline — untestable without mocking
  Azure. Pulled the decision logic into `evaluate_anomaly(daily_costs, *,
  threshold_pct, minimum_baseline_usd, cooldown_days, last_alert_utc, now)`
  returning a `Decision(outcome, delta_pct)`. No I/O, no clock, no globals. The
  entrypoint now just gathers inputs, calls it, and acts on the outcome. Built
  test-first: 7 tests (one per branch — anomaly, within-threshold, below-baseline,
  suppressed-in-cooldown, alert-after-cooldown, insufficient-data, and
  lower-baseline-lets-low-spend-through) written and watched fail before the
  function existed. `tests/test_function_indexes.py` folds the old
  "does it import and register the trigger" CI check into the same suite.
- **`MINIMUM_BASELINE_USD` is now an app setting**, not a hardcoded `1.0`.
  Threaded through `main.bicep` → `resources.bicep` like the other three tunables,
  with `"${MINIMUM_BASELINE_USD=1.0}"` in `main.parameters.json` so it has a
  working default without requiring `azd env set`. This subscription spends
  ~$0.19/day, so with the old hardcoded floor the tool was *permanently* in
  skip-mode; the setting lets a low-spend subscription opt back into
  percentage-based detection.

Side effect of the refactor: the dedupe-state blob is now read on every run (via
`_read_last_alert_time`, which swallows a storage failure and returns `None`
rather than crashing) instead of only on anomaly days. One extra small blob read
daily, in exchange for the cooldown decision living inside the pure function and
storage issues showing up in the logs every day instead of only during an incident.

Redeployed and verified: `azd provision` landed `MINIMUM_BASELINE_USD=1.0`,
`azd deploy` reindexed `cost_anomaly_check`, a manual invoke exercised the new code
path (still 429 from the Cost Management API after a session of repeated manual
triggers — handled cleanly, as designed).

## Security pass — identifier hygiene + a missing data-plane role

A later review against the pre-flight checklist turned up one real bug and some
housekeeping.

**The bug: the dedupe-state blob code had no permission to run.** `_state_container`
builds a `BlobServiceClient` with `DefaultAzureCredential` — the Function's managed
identity — but the only role assignment in `resources.bicep` was Cost Management
Reader, which grants nothing on the blob data plane. So every read of
`last-alert.json` was a silent 403 (swallowed by `_read_last_alert_time`, treated
as "no prior alert") and the write in `_set_last_alert_time` was an *unguarded*
403 — an anomaly-day run would emit the alert trace, then crash, showing as a
failed execution in the portal. The cooldown / repeat-suppression feature had
therefore never actually worked. It went unnoticed because the only end-to-end
test of the alert path was a synthetic App Insights trace (see "Testing the alert
path" above), which never exercises the blob code.

Why the earlier reasoning missed it: the Stage-2 note "host storage via account
key, not identity-based connection" correctly decided the *Functions host*
connection (`AzureWebJobsStorage`) didn't need data-plane roles — but the
application's *own* state blob is separate code using the identity directly, and
that distinction got lost.

Fix:

- **`resources.bicep`**: added a `Storage Blob Data Contributor`
  (`ba92f5b4-2d11-453d-a403-e96b0029c9fe`) role assignment for the Function's
  identity, scoped to the single `state` container — not the storage account, not
  the subscription. Least-privilege: the identity can read/write blobs in that one
  container and nothing else.
- **`function_app.py`**: wrapped `_set_last_alert_time` in try/except so a storage
  failure (including the few minutes of RBAC propagation lag right after a fresh
  `azd provision`) logs a warning instead of failing a run that has already sent
  the alert. Mirrors the philosophy already in `_read_last_alert_time`.

**Still to verify against the live subscription:** the cost query runs at
`/subscriptions/<SUBSCRIPTION_ID>` scope, but Cost Management Reader is assigned at
resource-group scope, which does not authorize a subscription-scoped query. The
one manual invoke logged above hit a `429` throttle before any authorization
check, so this path has never returned real data. If it `403`s in production it is
caught by `except AzureError` → "skipping this run" → the anomaly check silently
never fires. Trigger the deployed function once outside a throttle window and
confirm a `200` on the `/query` call before treating this as closed.

**Housekeeping (identifier hygiene):**

- `azure-naming-conventions.md` gained a "Documentation placeholders" section —
  the canonical `<TENANT_ID>` / `<SUBSCRIPTION_ID>` / `<PRINCIPAL_ID>` tokens, a
  redact-at-capture-time rule for this command log, and the `git grep` pre-commit
  scan.
- One partial subscription-ID prefix in this file's command log was replaced with
  `<SUBSCRIPTION_ID>`. The Cost Management Reader role definition GUID stays as-is
  — built-in role IDs are identical in every tenant and are not sensitive.
- `.gitignore` now excludes `docs/superpowers/` (internal planning docs are kept
  locally, not published).

## CLI command log

| Command | What it did / why |
|---|---|
| `git init` | Created a project-scoped `.git` inside `azure-cost-sentinel/`, isolating it from a stray `.git` at the Windows user profile root that would otherwise have been picked up. |
| `git add README.md` / `git commit` | First commit — README skeleton only. |
| `gh repo create RealityLVN/azure-cost-sentinel --public --source=. --remote=origin --push` | Published the repo under the RealityLVN org and pushed the initial commit, using the already-authenticated `gh` CLI login rather than widening the GitHub MCP token's permissions. |
| `winget install microsoft.azd` *(failed — winget not on PATH)* | First attempt to install the Azure Developer CLI; fell back to Microsoft's official install script. |
| `Invoke-RestMethod 'https://aka.ms/install-azd.ps1' \| Invoke-Expression` | Installed `azd` 1.32.0 via Microsoft's official installer (MSI, user-scoped install under `AppData\Local\Programs`). |
| `azd init -m -e dev --no-prompt` | Scaffolded a minimal `azd` project (`azure.yaml` only, environment named `dev`) — the "Bicep starter pattern" the spec calls for, extended from rather than hand-rolled. |
| `az login` | Switched the `az` CLI from a stale former-employer login to `jonathan@realitylvn.com`, landing on the correct "LVN Subscription" by default. |
| `azd auth login --check-status` | Confirmed `azd` was already authenticated as the same correct account (separate credential cache from `az`, but already in sync). |
| `az role definition list --name "Cost Management Reader"` | Looked up the built-in role's exact GUID (`72fafb9e-0641-4937-9268-a91bfd8191a3`) instead of guessing it, before hardcoding it into the role assignment in Bicep. |
| `az bicep install` | Installed the Bicep CLI (not present yet) so `az bicep build` could run. |
| `az bicep build --file infra/main.bicep` | Compiled the drafted template to check for syntax/type errors before anyone looks at a `what-if` plan — came back clean. |
| `azd env set AZURE_LOCATION eastus2` | Set the deployment region. Unlike the budget amount, threshold %, and notification email, region is a low-stakes technical default, not a personal/business decision, so set directly rather than asked. |
| `azd env set ANOMALY_THRESHOLD_PCT 25` / `ALERT_COOLDOWN_DAYS 3` / `BUDGET_AMOUNT_USD 5` / `NOTIFICATION_EMAIL ...` | Set the four values the spec explicitly calls out as personal/business decisions, not defaults to invent. |
| `azd env set AZURE_SUBSCRIPTION_ID ...` | `azd provision --preview` requires this explicitly even though `az` already had the right subscription selected — azd reads its own environment, not the ambient `az` context. |
| `azd provision --preview` | The what-if dry run — compiled and validated the template against the real subscription with no changes applied. Failed preflight on `SubscriptionIsOverQuotaForSku` for the Y1 App Service plan (see "Platform quirks" above). Quota increase requested via Portal, pending a support engineer — rerun this once it clears. |
| `az vm list-usage --location <region>` (several regions) | Checked Compute VM quota to rule out a Compute-side cause — all healthy, confirming the blocker was App Service-specific quota instead. |
| `azd env new cost-sentinel-dev` / `azd env select cost-sentinel-dev` | Replaced the generic `dev` environment name with the portfolio naming convention before anything was provisioned; old `dev` env left in place, not deleted. |
| `azd env set ...` (x6, repeated on the new environment) | Re-applied all previously-configured values (region, thresholds, budget, email, subscription) onto `cost-sentinel-dev` so nothing was lost in the rename. |
| `az deployment sub what-if` (rerun after naming/tagging fix) | Confirmed all 12 resources now carry the correct `<type>-cost-sentinel-dev` names and the four portfolio tags, before touching `azd provision`. |
| `az functionapp function list -g rg-cost-sentinel-dev -n func-...` | The verification step `azd deploy` doesn't do for you. Came back empty twice — "deploy succeeded" but zero functions indexed. This is *the* check that catches a silently-broken Python deploy. |
| `curl -s -H "x-functions-key: $KEY" .../admin/host/status` and `.../admin/functions` | Went straight to the Functions runtime: host `state: Running`, `admin/functions` → `[]`. Confirmed the host was healthy and the problem was function *indexing*, not the host or the plan. Kudu's `/api/command`, `/api/vfs`, and log stream are all disabled on Linux Consumption, so the runtime admin API was the only window in. |
| `python -m venv` + `pip install -r requirements.txt` + `app.get_functions()` (local) | Reproduced the worker's indexing step in a clean venv. `ImportError: cannot import name 'SubscriptionClient'` — the root cause, found locally in seconds instead of guessing against the deployed app. |
| `az bicep build --file infra/main.bicep` (rerun) | Re-validated the template after adding the `AZURE_SUBSCRIPTION_ID` app setting — clean. |
| `azd provision --no-prompt` (Deploy #2 fix) | Pushed the new `AZURE_SUBSCRIPTION_ID` app setting onto the existing Function App. Idempotent — the other 6 resources reported "Done" with no changes. |
| `azd deploy --no-prompt` (Deploy #2 fix) | Redeployed the function with pinned `requirements.txt` and the `azure-mgmt-resource` dependency gone. |
| `curl -H "x-functions-key: <masterKey>" .../admin/functions` (post-fix) | The authoritative "did it actually work" check. Returned the `cost_anomaly_check` entry with its `timerTrigger` binding — non-empty at last. |
| `az monitor log-analytics query -w <customerId> --analytics-query "AppExceptions \| ..."` | Pulled the Function host's own startup logs straight from the workspace. Showed the pre-fix `ImportError`/`Worker failed to index functions` and the post-fix `1 functions loaded` / `Found: Host.Functions.cost_anomaly_check`. The `az monitor app-insights query` equivalent returned nothing for this workspace-based component — the workspace query is what works. |
| `az monitor action-group test-notifications create -g ... --action-group-name ag-... -a email primary <addr> usecommonalertschema --alert-type budget` | Azure's built-in Action Group test. Returned `Status: Succeeded` for the email mechanism — confirms delivery without needing an alert to fire. Note: it does *not* read the group's existing receivers, you pass them explicitly with `-a`. |
| `python … urllib POST https://<region>.in.applicationinsights.azure.com/v2.1/track` | Injected a synthetic `AnomalyDetected` `MessageData` trace using just the instrumentation key (no RBAC), to test the `scheduledQueryRules` alert without deploying test code. Landed in `AppTraces`; the rule fired the Action Group on its next evaluation. |
| `azd env remove dev --force` | Deleted the stale local `dev` azd environment. Local-only operation — `.azure/dev/` was gitignored and never provisioned anything. |
| `az extension add -n application-insights` / `-n log-analytics` / `-n scheduled-query` | Installed the CLI extensions these diagnostics need — they prompt interactively (and so fail under automation) if missing. |
| `pytest -q` (local + CI) | 8 tests: `evaluate_anomaly` branch coverage + the worker-indexes-the-trigger assertion. Runs with no Azure and no clock because all I/O stays in the timer entrypoint. |
| `azd env set MINIMUM_BASELINE_USD 1.0` | Made the trailing-average floor a real tunable instead of a hardcoded constant — the fourth `azd env set` value, alongside threshold / cooldown / budget. |
| `azd provision --preview --no-prompt` (baseline change) | Confirmed azd accepts the `"${MINIMUM_BASELINE_USD=1.0}"` default syntax in `main.parameters.json` and the template still compiles before applying. |
| `azd provision` + `azd deploy` (baseline + refactor) | Landed the new app setting, redeployed the refactored function. Verified `MINIMUM_BASELINE_USD=1.0` on the app and `admin/functions` still non-empty. |
| `git grep -nIE '<guid>\|/subscriptions/<36>\|*.onmicrosoft.com'` (security pass) | Pre-commit identifier scan from `azure-naming-conventions.md`. Only non-placeholder hit was one truncated subscription-ID prefix in this command log — replaced with `<SUBSCRIPTION_ID>`. |
| `az bicep build --file infra/main.bicep` (security pass) | Re-validated the template after adding the `Storage Blob Data Contributor` role assignment — clean. |
| `pytest -q` (security pass) | 8 tests still green after guarding `_set_last_alert_time`. |

## AZ-900 / AZ-104 domain mapping

- **Cost management & billing**: the entire Function is built around the Cost
  Management API and the concept of a Budget + cost alert (Stage 2) — direct
  reinforcement of the AZ-900 "cost management" domain.
- **Governance**: scoping the Managed Identity to Cost Management Reader at the
  resource-group level (Stage 2) is a hands-on example of least-privilege RBAC,
  core to both AZ-900 and AZ-104 governance domains. The security pass added a
  second lesson — control-plane roles (Cost Management Reader) and data-plane
  roles (Storage Blob Data Contributor) are separate grant systems; holding one
  says nothing about the other, and the blob code silently failed until the
  data-plane role was assigned.
- **Monitoring**: Application Insights with a capped daily ingestion cap and short
  retention, and the Action Group email notification (Stage 2), map to the AZ-900
  monitoring domain and AZ-104's Azure Monitor coverage.
- **Service limits & quotas**: hitting `SubscriptionIsOverQuotaForSku` on the Y1 plan,
  and learning it's a separate App Service quota family from Compute VM quota, is
  direct, hands-on AZ-104 "manage subscriptions and governance" material — quota is
  its own topic there, distinct from RBAC/policy.
- **Availability & scaling**: the zone-redundancy question (Consumption/Y1 doesn't
  support it, Premium does) is core AZ-104 "implement and manage storage" /
  availability content — the kind of specific plan-tier capability detail that's easy
  to get wrong on the exam without having hit it in a real quota form.
- **Deployment & IaC**: the whole `infra/` tree is Bicep provisioned through `azd`,
  and `.github/workflows/validate.yml` gates every change on `az bicep build` — the
  AZ-104 "automate deployment of resources" objective, and the practical half of it
  (a template that compiles is not a template that works — see both Deploy sections).
