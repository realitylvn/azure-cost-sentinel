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

## AZ-900 / AZ-104 domain mapping

- **Cost management & billing**: the entire Function is built around the Cost
  Management API and the concept of a Budget + cost alert (Stage 2) — direct
  reinforcement of the AZ-900 "cost management" domain.
- **Governance**: scoping the Managed Identity to Cost Management Reader at the
  resource-group level (Stage 2) is a hands-on example of least-privilege RBAC,
  core to both AZ-900 and AZ-104 governance domains.
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
