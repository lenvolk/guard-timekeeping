# guard-timekeeping

A four-hour Azure workshop. Each team uses Bicep to deploy a three-tier
timekeeping app for a security-guard workforce. Guards sign on screen, and the app
stores the signatures in Blob Storage. The app uses synthetic data only.

> Status: the [plan](plan.md) is agreed. The scripts, Bicep templates and app are
> being built and tested gate by gate. Commands below work once gate G4 is done.

## What you deploy

![Architecture: public web app and API in rg-app; PostgreSQL and a storage account in rg-data; the API joins a VNet in rg-app and reaches storage through a private endpoint](docs/diagrams/architecture.excalidraw.svg)

| Tier | Resource group | Azure service | How access works |
|---|---|---|---|
| Web | `rg-<team>-app` | App Service, Linux B1 | Public, anonymous demo personas |
| API | `rg-<team>-app` | App Service, same plan | Public |
| Database | `rg-<team>-data` | PostgreSQL Flexible Server, B1ms | Azure services only, Entra sign-in only |
| Signatures | `rg-<team>-data` | Storage account, `signatures` container | Entra identities only, keys turned off |
| Network | `rg-<team>-app` | VNet, blob private endpoint, private DNS zone | The API joins the VNet and reaches storage privately |

The API's managed identity is the PostgreSQL admin and has the Storage Blob Data
Contributor role. No password or storage key exists anywhere. The API reaches Blob
Storage through a private endpoint, so the app still works when a subscription
policy turns off public network access on storage accounts. Full private
networking is left for production.

The **runner** in the diagram is you: the account signed in to the Azure CLI that
runs `deploy.ps1`. S2 gives that account Storage Blob Data Reader so you can open
the signature PNGs in the Azure portal. Keys are turned off, so the portal uses
your Entra sign-in and needs that role.

> If a policy has turned off public network access, the portal cannot list the
> `signatures` container from your laptop. Use the supervisor page to see the
> signatures instead.

## How deployment runs

![deploy.ps1 asks for Human in the loop or Autopilot, then runs stages S0 to S3; cleanup S4 needs the team name](docs/diagrams/deployment-stages.excalidraw.svg)

```powershell
git clone https://github.com/lenvolk/guard-timekeeping.git
cd guard-timekeeping
.\scripts\Test-Prerequisites.ps1
.\deploy.ps1
```

The script first asks for a mode:

- **Human in the loop** (default) pauses after each stage. Review the results in
  the console and the portal, then type `y` to continue.
- **Autopilot** deploys everything and runs every check in one go. It stops only on
  a failure.

It then asks for any value you leave out. Press Enter to accept the default.

| Parameter | Default |
|---|---|
| `-Mode` | `Interactive` (or `Autopilot`) |
| `-Team` | `team01` |
| `-SubscriptionId` | Your current `az account` subscription |
| `-Location` | `eastus2` |
| `-StartAt` | `S0` |

If a team falls behind, `.\deploy.ps1 -Team team01 -Mode Autopilot -StartAt S2`
catches up from S2. For a hackathon, `.\scripts\Test-Prerequisites.ps1 -TeamCount 5`
checks regional quota for five teams. Give each team its own `-Team` name.

If the preflight says PostgreSQL does not accept new servers in your region, pick
another region with `-Location`, for example `centralus` or `westus3`. Some
subscriptions block new PostgreSQL servers in eastus2 and eastus.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with Bicep (`az bicep install`)
- Owner on the Azure subscription, or Contributor plus Role Based Access Control
  Administrator. The deployment creates role assignments.
- git, or this repository downloaded as a zip

## Try the app

Open the web URL that S3 prints. Pick a site and a guard.

1. Start a shift, pick a witness and sign.
2. Take a vacant post.
3. Hand the post to a relief guard, who signs to accept.
4. End the shift and sign.

The supervisor page shows covered posts, the event history and signature
thumbnails. If your subscription allows public access to storage, you can also
open the storage account in the Azure portal, then the `signatures` container, to
see the same PNG files.

[demo.md](demo.md) walks through these steps one click at a time and explains what
each one proves. To run them again, click **Reset** in the top bar. It deletes all
activity and signatures and loads the synthetic data again.

## Clean up

S4 deletes both resource groups after you type the team name. Autopilot never runs
it. To run only the cleanup:

```powershell
.\deploy.ps1 -Team team01 -StartAt S4
```

## Before production

![Production: network engineers, database admins and app developers each get a scoped role on their own resource group](docs/diagrams/production-rbac.excalidraw.svg)

This workshop takes shortcuts. Production needs at least:

- a VNet with private endpoints for the database and API (storage already has one)
- scoped roles per resource group instead of one subscription Owner
- Entra sign-in instead of picking a persona
- no Reset page: anyone on the site can wipe all data with it
- legally approved e-signatures with retention and immutable storage
- least-privilege database roles and versioned migrations
- CI/CD with protected environments instead of laptop prompts
- a WAF, zone redundancy, tested backups and alerts
- approved labor, break and pay rules

Section 11 of the [plan](plan.md#11-production-follow-up) has the full list.

## Diagrams

The diagrams are `.excalidraw.svg` files: architecture, deployment stages,
production roles, and the [demo.md](demo.md) test flow. GitHub shows them as images, and the
[Excalidraw VS Code extension](https://marketplace.visualstudio.com/items?itemName=pomdtr.excalidraw-editor)
opens them for editing. To regenerate them from code, run `npm install` and
`node render.mjs` in [tools/diagrams](tools/diagrams). This needs Node.js and
Microsoft Edge.

## Copilot setup for contributors

The repository includes MCP server settings for GitHub Copilot. Attendees do not
need them.

| Server | Gives Copilot | Runs |
|---|---|---|
| `azure` | Azure resource queries, Bicep and Terraform guidance | `npx @azure/mcp` |
| `microsoft-learn` | Microsoft and Azure docs and code samples | Remote HTTP |
| `github` | Repositories, issues, pull requests, Actions (VS Code only) | Remote HTTP |
| `playwright` | Browser automation for UI tests | `npx @playwright/mcp` |

VS Code reads [.vscode/mcp.json](.vscode/mcp.json). Start each server from that
file or run `MCP: List Servers`. Copilot CLI reads [.github/mcp.json](.github/mcp.json).
Check it with `/mcp`. Both need Node.js LTS, the Azure CLI signed in with
`az login`, and a GitHub sign-in.

## License

[MIT](LICENSE)
