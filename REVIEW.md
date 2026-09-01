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

## CLI command log

| Command | What it did / why |
|---|---|
| `git init` | Created a project-scoped `.git` inside `azure-cost-sentinel/`, isolating it from a stray `.git` at the Windows user profile root that would otherwise have been picked up. |
| `git add README.md` / `git commit` | First commit — README skeleton only. |
| `gh repo create RealityLVN/azure-cost-sentinel --public --source=. --remote=origin --push` | Published the repo under the RealityLVN org and pushed the initial commit, using the already-authenticated `gh` CLI login rather than widening the GitHub MCP token's permissions. |
| `winget install microsoft.azd` *(failed — winget not on PATH)* | First attempt to install the Azure Developer CLI; fell back to Microsoft's official install script. |
| `Invoke-RestMethod 'https://aka.ms/install-azd.ps1' \| Invoke-Expression` | Installed `azd` 1.32.0 via Microsoft's official installer (MSI, user-scoped install under `AppData\Local\Programs`). |
| `azd init -m -e dev --no-prompt` | Scaffolded a minimal `azd` project (`azure.yaml` only, environment named `dev`) — the "Bicep starter pattern" the spec calls for, extended from rather than hand-rolled. |

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
