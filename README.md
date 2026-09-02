# [Project Name]

> [One-sentence business pitch — the exact line from the portfolio plan, e.g. "Watches an Azure subscription's spend and flags anomalies in plain English before they become a surprise bill."]

![Azure](https://img.shields.io/badge/Azure-Functions-0078D4?logo=microsoftazure)
![Bicep](https://img.shields.io/badge/IaC-Bicep-0078D4)
![GitHub Actions](https://img.shields.io/badge/CI%2FCD-GitHub_Actions-2088FF?logo=githubactions&logoColor=white)
![Cost](https://img.shields.io/badge/monthly_cost-%240–%240.05-brightgreen)

## The problem

[2–3 sentences, plain English, no jargon. Who has this problem and why it's annoying/risky. This is the section a non-technical hiring manager reads.]

## What it does

[3–5 bullets, concrete. "Runs on a timer every X. Calls Y API. Flags Z when threshold is exceeded. Posts a summary to [where]."]

## Architecture

[Diagram — even a simple boxes-and-arrows PNG/SVG exported from draw.io or excalidraw works better than a wall of text. Embed it: `![architecture](docs/architecture.png)`]

**Services used:** [list — Functions, Bicep, Monitor, etc.]
**Auth:** Managed Identity secures all Cost Management API access (the tool's core function) — no credentials in code. The Function host's own runtime storage connection uses a platform-managed key via app settings, azd's standard default, not a manually handled secret.

## Environment

[Choose the version that matches this project:]

_Self-use projects (Cost Sentinel / Drift Detector / NSG Scanner):_ Runs against a live Azure subscription I co-administer — not a disposable sandbox. I have a direct interest in catching cost anomalies, drift, and exposed rules here since it's infrastructure I'm actually responsible for.

_Offboarding Automator:_ Built and tested against a free Microsoft 365 Developer Program tenant with synthetic test users — the tenant and API calls are real (Graph API, real permission changes), the employee scenario is simulated since it's a purpose-built dev environment rather than a live business with headcount turnover. [Optional, if true: "I've handled anomaly detection and alerting in a production capacity in my sysadmin work — this project formalizes that experience into a repeatable, auditable automation."]

## What this doesn't do

[Explicit, honest scope boundary — the anti-black-box section. e.g. "This flags anomalies against a static threshold; it doesn't yet learn seasonal spend patterns. In a production deployment, [X] would sit behind Entra ID SSO for the operator console — omitted here so the repo stays publicly browsable."]

## Running it yourself

```bash
az login
az deployment group create --resource-group <rg> --template-file infra/main.bicep
```

[Any config/parameters needed. Keep this section honest about what's a placeholder vs. what actually works out of the box.]

## Sample output

[Screenshot or a sanitized JSON/log snippet showing the tool actually working — this is the single most persuasive thing in the whole README, don't skip it. For Cost Sentinel specifically: report anomalies as relative deltas or percentages ("34% above 7-day average"), not dollar figures — keeps the output meaningful without disclosing actual spend.]

## Cost

Built entirely on Azure's free-tier grants (Functions Consumption: 1M executions/month free). Estimated cost if left running indefinitely: **under $0.05/month**. A budget alert is provisioned in `infra/` as a safety net regardless.

## Built with

Designed and reviewed with Claude (architecture, spec-tightening, README), implemented with Claude Code / Azure CLI in VS Code.

---

_Part of a 4-project Azure/M365 portfolio series: [links to the other three once live]_
