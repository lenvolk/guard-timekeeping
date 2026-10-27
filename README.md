# guard-timekeeping

A four-hour Azure workshop. Each team uses Bicep to deploy a three-tier
timekeeping app for a security-guard workforce. Guards sign in on a shared tablet,
start and end shifts, take posts and breaks, and sign on screen for every change of
responsibility. Supervisors approve corrections and review a daily record. The
app stores the signatures in Blob Storage and uses synthetic data only.

> Status: the [plan](plan.md) is agreed. The scripts, Bicep templates and app are
> being built and tested gate by gate. Commands below work once gate G4 is done.

## What you deploy

![Architecture: public web app and API in rg-app; PostgreSQL and a storage account in rg-data; the API joins a VNet in rg-app and reaches storage through a private endpoint](docs/diagrams/architecture.excalidraw.svg)

| Tier | Resource group | Azure service | How access works |
|---|---|---|---|
| Web | `rg-<team>-app` | App Service, Linux B1 | Public. People sign in with employee ID and date of birth |
| API | `rg-<team>-app` | App Service, same plan | Public address, but answers only the web app (shared key) |
| Database | `rg-<team>-data` | PostgreSQL Flexible Server, B1ms | Azure services only, Entra sign-in only |
| Signatures | `rg-<team>-data` | Storage account, `signatures` container | Entra identities only, keys turned off |
| Network | `rg-<team>-app` | VNet, blob private endpoint, private DNS zone | The API joins the VNet and reaches storage privately |

The API's managed identity is the PostgreSQL admin and has the Storage Blob Data
Contributor role. It also has Contributor on the PostgreSQL server only, so the
Status page can start the server when it is stopped. No password or storage key
exists anywhere. The API reaches Blob
Storage through a private endpoint, so the app still works when a subscription
policy turns off public network access on storage accounts. Full private
networking is left for production.

> Some subscriptions run automation that stops idle PostgreSQL servers overnight.
> If every page says *The database is not available*, open **Status** and select
> **Start database**. The page turns green by itself in about 2 minutes.
> `deploy.ps1` also starts a stopped server before it runs S1, S2 or S3.

The **runner** in the diagram is you: the account signed in to the Azure CLI that
runs `deploy.ps1`. S2 gives that account Storage Blob Data Reader so you can open
the signature PNGs in the Azure portal. Keys are turned off, so the portal uses
your Entra sign-in and needs that role.

> If a policy has turned off public network access, the portal cannot list the
> `signatures` container from your laptop. Use the daily record to see the
> signatures instead.

## What the app does

One continuous transaction chain, built for a shared tablet at each site:

| Step | In the app |
|---|---|
| **Identify** | Sign-in with employee ID and date of birth. Guards see only their own page, supervisors only their site (a regional supervisor sees both). Five wrong tries lock the ID for five minutes |
| **Transact** | Start and end a shift, take a post, take a lunch (60 min) or restroom (15 min) break with an available guard covering, hand over a post. Steps out of order are refused with a message |
| **Sign** | A finger or stylus signature on every change of responsibility. Each one stores the signer, the time, its meaning and a SHA-256 fingerprint. The relief or cover guard confirms with their own date of birth before signing |
| **Supervise** | Guards request time corrections with a reason. A supervisor approves or rejects them. Overdue breaks, long shifts and locked IDs are flagged under **Needs attention** |
| **Audit** | A daily record per site with original and corrected times, signature checks, print and CSV export. Nothing recorded is ever changed |

The design uses 21 CFR Part 11, the FDA rule for electronic records and signatures,
as a benchmark. [pilot.md](pilot.md) maps each control and lists the gaps.
[demo.md](demo.md) has the sign-in details and a click-by-click walkthrough.

## How deployment runs

![deploy.ps1 asks for Human in the loop or Autopilot, then runs stages S0 to S3; cleanup S4 needs the team name](docs/diagrams/deployment-stages.excalidraw.svg)

```powershell
git clone https://github.com/lenvolk/guard-timekeeping.git
cd guard-timekeeping
.\scripts\Test-Prerequisites.ps1
.\deploy.ps1
```

Run `deploy.ps1` from the repository root, not from the `scripts` folder. To skip
the questions, pass the answers. This deploys team01 to North Central US without
pausing:

```powershell
.\deploy.ps1 -Mode Autopilot -Team team01 -Location northcentralus
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
| `-Location` | Picked from a list (see below) |
| `-StartAt` | `S0` |

If a team falls behind, `.\deploy.ps1 -Team team01 -Mode Autopilot -StartAt S2`
catches up from S2. For a hackathon, `.\scripts\Test-Prerequisites.ps1 -TeamCount 5`
checks regional quota for five teams. Give each team its own `-Team` name.

When you leave out `-Location`, both scripts list common US regions and mark the
ones where your subscription can deploy the workshop. A region is blocked when the
subscription cannot create PostgreSQL there, or when its App Service B1 quota is 0.
Type a number from the list, a region name such as `centralus`, or the portal name
such as `Central US`:

```text
   [1] eastus           East US            blocked: this subscription cannot create PostgreSQL here
   [3] centralus        Central US         ok
   [6] westus           West US            blocked: App Service B1 quota is 0 here
   ...
   Pick a number or type a region [centralus]:
```

## Prepare a region

The easiest fix is to pick a region marked **ok**. If you need a specific region,
for example to stay close to the customer, unblock it a few days before the
workshop. Each subscription and region is separate, so repeat this for every
subscription the teams use.

| Blocked because | What to request | How long |
|---|---|---|
| App Service B1 quota is 0 | A higher **B1** limit for that region | Usually minutes |
| The subscription cannot create PostgreSQL | **Region access** for PostgreSQL Flexible Server | 24 to 48 hours, and can be refused where capacity is tight |

**App Service B1 quota** (you need the Owner or Quota Request Operator role):

1. In the [Azure portal](https://portal.azure.com), search for **Quotas** and open
   it.
2. Select **App Service**, then filter by your subscription and the region.
3. Select the **B1** row and request a new limit: the current usage plus one per
   team, for example 5 for five teams.

Do not request *Total Regional VMs*. It goes up with the B1 increase.

**PostgreSQL region access:**

1. In the Azure portal, open **Help + support**, then **Create a support request**.
2. For **Issue type**, pick **Service and subscription limits (quotas)**. For
   **Quota type**, pick **Azure Database for PostgreSQL flexible server**.
3. On **Additional details**, select **Enter details**, choose **Region access**,
   pick the region, and enter 1 vCore per team.
4. Submit the request. You get an email when it is approved.

When the requests are approved, confirm the region is ready for all teams:

```powershell
.\scripts\Test-Prerequisites.ps1 -Location westus -TeamCount 5
```

Microsoft docs:
[App Service quota](https://learn.microsoft.com/troubleshoot/azure/app-service/troubleshoot-non-zone-redundant-quota-requests),
[PostgreSQL quota and region access](https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-request-quota-increase).

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with Bicep (`az bicep install`)
- Owner on the Azure subscription, or Contributor plus Role Based Access Control
  Administrator. The deployment creates role assignments.
- A region where the subscription can create PostgreSQL and has App Service B1
  quota. The scripts show which regions qualify. See [Prepare a region](#prepare-a-region).
- git, or this repository downloaded as a zip

## Try the app

Open the web URL that S3 prints and sign in as guard `G-1001`, date of birth
`03/14/1988`. All sign-in details are in [demo.md](demo.md).

1. Start a shift, pick a witness and sign.
2. Take a vacant post.
3. Take a lunch break. An available guard confirms with their date of birth and
   signs to cover the post. Return from the break and sign.
4. Hand the post to a relief guard, who confirms and signs to accept.
5. End the shift and sign, then request a correction of the end time.
6. Sign in as supervisor `S-1001`, approve the correction, and open the daily record.

[demo.md](demo.md) walks through these steps one click at a time and explains what
each one proves. To run them again, sign in as a supervisor and click **Reset**. It
deletes all activity and signatures and loads the synthetic data again.

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
- Microsoft Entra ID or a PIN instead of employee ID and date of birth, which is
  weak as a password even though only a salted hash is stored
- an Entra token or private networking between the web app and the API instead of
  a shared key
- no Reset page, and no Start database button with Contributor on the server
- legally approved e-signatures with 10-year retention and immutable storage
- least-privilege database roles and versioned migrations
- CI/CD with protected environments instead of laptop prompts
- a WAF, zone redundancy, tested backups and alerts
- approved labor, break and pay rules

[pilot.md](pilot.md) lists the security, recovery and compliance gaps against
21 CFR Part 11. Section 11 of the [plan](plan.md#11-production-follow-up) has the
full list.

## Diagrams

The diagrams are `.excalidraw.svg` files: architecture, deployment stages,
production roles, the [demo.md](demo.md) test flow and the [pilot.md](pilot.md)
compliance map. GitHub shows them as images, and the
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
