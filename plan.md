# Timekeeping workshop plan

Status: agreed on 2026-10-26. Implementation starts in a new session and follows
[section 9](#9-implementation-gates) one gate at a time.

## 0. Rules for the implementing session

- This file is the source of truth. If `README.md`, `docs/decisions/` or
  `docs/glossary.md` disagree with it, follow this file and fix the other file in
  the gate that owns it.
- Work through gates G0 to G7 in order. At the end of each gate, show the evidence
  listed for it, stop and wait for the sponsor's approval. Do not start the next
  gate without it.
- Deploy only to the subscription the sponsor confirms at G1. Ask before any
  deletion other than S5 on a team the session created.
- After each approved gate, commit locally with a message naming the gate. Push
  only at G7, or earlier if the sponsor asks.
- Never read, copy or quote anything from folders outside this repository,
  including any sibling planning folder. The repository is public. Use only
  generic names and fictional people.
- Follow `.github/skills/unslop/SKILL.md` for all prose. Never use Mermaid. Draw
  diagrams with Excalidraw: preview them with the Excalidraw MCP server, then edit
  `tools/diagrams/render.mjs` and run it to write `docs/diagrams/*.excalidraw.svg`.
  Screenshot the result and check that no labels overlap.
- If a risk in section 9 fails, or a change would alter a decision in section 3,
  stop and ask. Do not quietly widen scope or make the backend public.

## 1. Summary

Attendees are new to Azure and do not need GitHub Copilot. In one four-hour
session, each team picks one person to run a PowerShell script on a laptop. The
script uses Bicep to deploy a three-tier timekeeping app in four stages. After each
stage it prints what it deployed and asks the runner whether to continue.

The app is a proof of concept for a generic security-guard workforce. It uses
synthetic data only. It contains no customer names, customer documents or real
people.

Attendees learn:

- how resource groups, a VNet, subnets and private DNS fit together
- how a web tier, an API tier and a database connect in Azure
- how a private endpoint keeps the database off the internet
- how a managed identity replaces a database password
- how Bicep deploys and redeploys resources
- what must change before UAT or production

## 2. Requirements

| ID | Requirement |
|---|---|
| R1 | The session takes at most four hours and suits people new to Azure. |
| R2 | Bicep provisions all resources. No AKS. Attendees do not need GitHub Copilot. |
| R3 | DEV proof of concept with prepopulated synthetic data. |
| R4 | The web frontend is public. The database is reachable only through a private endpoint. |
| R5 | Deployment runs in stages. After each stage the script shows the result and asks the runner to continue. |
| R6 | One person per team runs the script on a local laptop. A prerequisite script checks the tools first. |
| R7 | The README gives step-by-step instructions with Excalidraw diagrams and follows the unslop rules. |
| R8 | Documentation lists what production needs, including RBAC per resource group. The workshop does not build it. |
| R9 | The repository is public. It must not contain customer names, customer material or real personal data. |

## 3. Decisions

| ID | Decision | Reason |
|---|---|---|
| D01 | Three tiers: a public web app, an API app and PostgreSQL Flexible Server. | Shows a multi-tier app without extra services. |
| D02 | One private endpoint, for PostgreSQL. An access restriction on the API allows only the web app's integration subnet, through a `Microsoft.Web` service endpoint. | A private endpoint on the API would need a VM or VPN to deploy code. Production adds it. |
| D03 | No deployment VM and no Bastion. The laptop deploys code through each app's SCM site. | Fits the four-hour limit. |
| D04 | The API's system-assigned managed identity is the PostgreSQL Entra administrator. Password authentication is off. | No passwords anywhere, and no SQL runs from the laptop. Production uses a least-privilege database role. |
| D05 | On startup, the API creates its tables and loads seed data if the database is empty. No migration tool and no migration exercise. | Nothing outside the VNet needs to reach the database. Production adds versioned migrations. |
| D06 | Each team gets three resource groups: network, data and app. Bicep creates no role assignments. The runner needs Contributor on the subscription. | Shows how production splits ownership with RBAC while the workshop needs only Contributor. |
| D07 | One `deploy.ps1` runs stages S0 to S5 and prompts `Continue? (y/n)` after each. `-StartAt` resumes from a stage. | A learning checkpoint, not a security control. |
| D08 | The scripts run in Windows PowerShell 5.1 and PowerShell 7. The only required tool is the Azure CLI with Bicep. | App Service builds the Python code, so laptops need no Python or Docker. |
| D09 | Anonymous persona selection, with a "synthetic data" banner on every page. | No sign-in setup. Production adds Entra sign-in. |
| D10 | Python 3.12. FastAPI for the API. FastAPI with Jinja2 templates for the web app, which calls the API from the server. The supervisor page reloads every 10 seconds. | One language and no JavaScript build step. |
| D11 | Team name, subscription, region, VNet range and team count are parameters with suggested defaults (see section 6). If the runner omits one, the script asks and Enter accepts the default. Resource names include the team name and a short unique suffix. | The same repository works for a hackathon of any size or a single user, with nothing customer-specific committed. `eastus2` is the default because `eastus` often refuses new PostgreSQL Flexible servers. App and server names must be globally unique. |
| D12 | Application Insights and Log Analytics in the app resource group. | Attendees need a place to look when something fails. |
| D13 | Cleanup deletes the team's three resource groups after the runner types the team name. | Stops charges. |
| D14 | MIT license. | The repository is public. |

The README and the GitHub repository description no longer name the customer.
Earlier commits stay as they are (agreed option a).

## 4. Architecture

[docs/diagrams/architecture.excalidraw.svg](docs/diagrams/architecture.excalidraw.svg)
shows this design. It has three resource-group zones. The browser calls the web
app in `rg-app`. The web app calls the API app. The API reaches PostgreSQL in
`rg-data` through the private endpoint, which takes its IP from `rg-network`'s
endpoint subnet. A red dashed line marks a direct internet call to the API, which
gets 403.

Request path:

1. The browser calls the web app over HTTPS.
2. The web app calls the API over HTTPS. VNet integration with "route all" sends
   this call through `snet-app-integration`. The API allows that subnet and returns
   403 to every other caller.
3. The API connects to PostgreSQL on port 5432. The private DNS zone resolves the
   server name to the private endpoint's IP. The API signs in with a token from
   its managed identity.

| Stage | Resource group | Resources |
|---|---|---|
| S1 | `rg-<team>-network` | VNet `10.20.0.0/16` (parameter). `snet-app-integration` `10.20.1.0/24`, delegated to `Microsoft.Web/serverFarms`, with a `Microsoft.Web` service endpoint. `snet-private-endpoints` `10.20.2.0/24`. Private DNS zone `privatelink.postgres.database.azure.com` linked to the VNet. |
| S2 | `rg-<team>-data` | PostgreSQL Flexible Server 16, Burstable B1ms, 32 GB, public access disabled, Entra authentication only. Database `timekeeping`. Private endpoint in `snet-private-endpoints` with a DNS zone group. |
| S3 | `rg-<team>-app` | Linux App Service plan B1. Web app and API app, Python 3.12, HTTPS only, VNet integration with route all. API access restriction for the integration subnet. The SCM site keeps its own open rules so the laptop can deploy. The API has a system-assigned identity and is set as PostgreSQL Entra admin through a module scoped to the data group. Log Analytics and Application Insights. App settings: `API_BASE_URL` on the web app, and `PGHOST`, `PGDATABASE` and `PGUSER` on the API. |
| S4 | none | Zip `src/web` and `src/api`, deploy with `az webapp deploy`, wait for startup, then run the checks. |

Each stage template has `targetScope = 'subscription'`, creates its resource group
and finds earlier resources by name with `existing`. Any stage can therefore run
again on its own.

### Implementation notes

These details are easy to get wrong. Check each against current Microsoft Learn
documentation and Bicep schemas while building.

| Topic | Note |
|---|---|
| Naming | Every template computes `suffix = take(uniqueString(subscription().id, team), 5)` the same way. Example names: `vnet-<team>`, `psql-<team>-<suffix>`, `asp-<team>`, `app-<team>-web-<suffix>`, `app-<team>-api-<suffix>`, `log-<team>`, `appi-<team>`. |
| Deployments | `az deployment sub create --name tk-<team>-s<n> --location <loc>`. Each template outputs the names and hostnames the checks need. The script reads them with `az deployment sub show`. |
| PostgreSQL authentication | `authConfig`: Entra authentication enabled, password authentication disabled, so no administrator password parameter. S3 adds a `flexibleServers/administrators` child named with the API identity's object ID, `principalType: 'ServicePrincipal'` and `principalName` set to the API app name. The API's `PGUSER` is that app name. |
| PostgreSQL network | `network.publicNetworkAccess: 'Disabled'`. The private endpoint uses group ID `postgresqlServer` and a `privateDnsZoneGroups` entry for the zone from S1. Do not use delegated-subnet (VNet-injected) mode. |
| API database connection | psycopg 3 with `sslmode=require`. Password is an access token from `DefaultAzureCredential` for scope `https://ossrdbms-aad.database.windows.net/.default`. Get a new token for each new connection, because tokens expire. |
| Startup race | Gunicorn starts several workers and each runs startup code. Wrap table creation and seeding in `pg_advisory_lock` so only one worker seeds. Seed only when `guards` is empty. |
| App startup | Startup command `gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000 main:app`. App setting `SCM_DO_BUILD_DURING_DEPLOYMENT=true`, so App Service installs `requirements.txt`. |
| Web to API | Web app: `vnetRouteAllEnabled: true` (or the current `outboundVnetRouting` equivalent). API: an `ipSecurityRestrictions` allow rule with `vnetSubnetResourceId` for `snet-app-integration`, default action Deny, and `scmIpSecurityRestrictionsUseMain: false` with SCM default action Allow. |
| Telemetry | `APPLICATIONINSIGHTS_CONNECTION_STRING` app setting and `azure-monitor-opentelemetry` in both apps. |
| Zip files | Windows PowerShell 5.1 `Compress-Archive` can write backslashes in entry names, which break Linux deployments. Build zips with `System.IO.Compression.ZipFile` and forward-slash entry names. Leave out `__pycache__` and `.venv`. |
| CLI errors | Check `$LASTEXITCODE` after every `az` call and stop on failure. Never print tokens or connection strings. |
| Seed data | Generic, made-up names only. Two sites in different US time zones, for example `America/New_York` and `America/Chicago`. |
| Web form routes | `POST /guard/{id}/start-shift`, `/guard/{id}/take-post`, `/assignment/{id}/relieve`, `/guard/{id}/end-shift`. `Test-Workflow.ps1` posts to these and checks the resulting page or status code. |

## 5. Application scope

### Walkthrough

1. Open the web URL and see the synthetic-data banner.
2. Pick a site and a guard persona.
3. Start a shift. Pick a different guard as witness and confirm "equipment on".
4. Take a vacant post.
5. Try to hand the post to a guard who is already on another post and see the
   rejection. Then hand it to an available relief guard.
6. The original guard is still on shift but off post. End the shift and confirm
   "equipment off".
7. Open the supervisor board. It shows covered and vacant posts, guards on shift
   and recent events.
8. Refresh the page. The data is still there.

### Data

Seed data has 2 sites, 4 posts (2 per site) and 12 fictional guards. Some guards
start on shift so relief has an available candidate and a busy one.

Tables: `sites`, `posts`, `guards`, `shifts`, `post_assignments`, `events`.
Partial unique indexes allow one open shift per guard, one open assignment per
post and one open assignment per guard. A violation returns HTTP 409 with a clear
message, which also stops double submissions.

### Rules

- The witness must be a different guard.
- A guard cannot start a second open shift.
- To take a post, the guard must be on shift, not on another post and at the same
  site, and the post must be vacant.
- The relief guard must be on shift, not on a post, not the same guard and at the
  same site. One transaction ends the old assignment and starts the new one.
- A guard cannot end a shift while on a post.
- Each successful action writes one event in the same transaction.
- The server stores UTC timestamps. Pages show the site's time zone.

### API and pages

API: `GET /healthz`, `GET /sites`, `GET /sites/{id}/board`, `GET /guards/{id}`,
`POST /shifts`, `POST /shifts/{id}/end`, `POST /assignments`,
`POST /assignments/{id}/relieve`, `GET /events?site_id=`.

Web pages: `/` (pick site and guard), `/guard/{id}`, `/supervisor/{site_id}`,
`/status` (shows whether the API and database respond, and the seed counts).

### Out of scope

Sign-in, signatures, breaks and lunch, payroll, notifications, offline use,
staffing recommendations, corrections, multi-region recovery, attendee code
changes and a unit test suite. The scripted walkthrough in S4 is the only
automated app test.

## 6. Scripts and stages

```powershell
.\scripts\Test-Prerequisites.ps1          # optional: -Location -TeamCount
.\deploy.ps1                              # optional: -Team -SubscriptionId -Location -VnetPrefix -StartAt
```

| Parameter | Script | Suggested default | Notes |
|---|---|---|---|
| `-Team` | `deploy.ps1` | `team01` | Lowercase letters and digits, 3 to 10 characters. Used in resource group and resource names. |
| `-SubscriptionId` | both | The current `az account show` subscription | The script prints the name and ID before using it. |
| `-Location` | both | `eastus2` | S0 checks that the region offers PostgreSQL B1ms and App Service B1. |
| `-VnetPrefix` | `deploy.ps1` | `10.20.0.0/16` | Each team has its own VNet, so teams can share the default. Subnets are the first two `/24` ranges. |
| `-TeamCount` | `Test-Prerequisites.ps1` | `1` | The facilitator sets the hackathon size. The script checks regional quota for that many teams. |
| `-StartAt` | `deploy.ps1` | `S0` | Resumes from a later stage. |

When a parameter is missing, the script prompts with the default in brackets, for
example `Region [eastus2]:`. It saves the chosen values to `.deploy/<team>.json`,
which git ignores, so a resumed run with `-Team` uses the same values.

For each stage, `deploy.ps1` prints the stage name and target resource group,
deploys, runs the stage checks and prints the results. Then it asks
`Review the results above. Continue to <next stage>? (y/n)`. Answering `n` stops
and prints the resume command. A failed deployment or check stops the script and
prints the error and the resume command.

| Stage | Action | Checks the script prints | Estimate |
|---|---|---|---|
| S0 | Preflight. Deploys nothing. | Azure CLI and Bicep versions, signed-in account, subscription, providers registered, PostgreSQL B1ms offered in the region. | 1 min |
| S1 | Network | Resource group, VNet and subnet ranges, delegation, service endpoint, DNS zone link. | 2 min |
| S2 | Data | Server state Ready, public access Disabled, endpoint connection Approved, private DNS A record. | 10 to 15 min |
| S3 | App tier | Both apps Running, VNet integration, API access restriction, API identity listed as PostgreSQL admin, Application Insights. | 5 min |
| S4 | Code | Web `/healthz` returns 200. `/status` shows the API and database respond with 2 sites, 4 posts and 12 guards. A direct call from the laptop to the API returns 403. `scripts/Test-Workflow.ps1` runs the main path and two rejected actions. | 5 to 10 min |
| S5 | Cleanup | Asks for the team name, deletes the three groups and reports progress. | 10 min, runs in Azure |

Gates G2 to G7 replace these estimates with measured times.

### Before the event

Each runner needs:

- Windows PowerShell 5.1 or PowerShell 7
- Azure CLI with Bicep (`az bicep install`). G1 sets the minimum version.
- git, or the repository downloaded as a zip
- Contributor on the workshop subscription
- network access to Azure and `*.scm.azurewebsites.net` through any corporate proxy

The facilitator:

- picks the subscription and region, or accepts the defaults
- runs `Test-Prerequisites.ps1 -TeamCount <n>` to check quota (one B1 plan and
  one B1ms server per team) and register `Microsoft.Network`, `Microsoft.Web`,
  `Microsoft.DBforPostgreSQL`, `Microsoft.Insights` and
  `Microsoft.OperationalInsights`
- hands out team names, for example `team01` to `team05`

A single person trying the kit alone runs both scripts with no parameters.

## 7. Agenda

| Time | Minutes | Activity |
|---|---:|---|
| 00:00-00:20 | 20 | App and architecture overview. Run `Test-Prerequisites.ps1` and S0. |
| 00:20-00:45 | 25 | S1. Explore the VNet, subnets and DNS zone in the portal. Approve. |
| 00:45-01:25 | 40 | S2. Break while PostgreSQL provisions. Explore the private endpoint and disabled public access. Approve. |
| 01:25-02:00 | 35 | S3. Explore the apps, VNet integration, access restriction and managed identity. Approve. |
| 02:00-02:30 | 30 | S4. Deploy code, read the checks, confirm the API returns 403 from the internet. Approve. |
| 02:30-03:10 | 40 | Walkthrough as guard and supervisor. Find the requests in Application Insights. |
| 03:10-03:35 | 25 | Production gaps, including RBAC per resource group. |
| 03:35-03:50 | 15 | S5 cleanup. |
| 03:50-04:00 | 10 | Buffer and questions. |

If a stage overruns, the facilitator shows the remaining steps on a prepared
deployment and says it is a demonstration.

## 8. Repository layout

```text
deploy.ps1
scripts/Test-Prerequisites.ps1
scripts/Test-Workflow.ps1
infra/s1-network.bicep
infra/s2-data.bicep
infra/s3-app.bicep
infra/modules/
src/api/        FastAPI app, schema.sql, seed data, requirements.txt
src/web/        FastAPI + Jinja2 app, templates, static CSS, requirements.txt
docs/diagrams/  architecture, deployment-stages, production-rbac (.excalidraw.svg)
docs/production-readiness.md
docs/glossary.md
tools/diagrams/ render.mjs regenerates the diagrams (Node.js, Microsoft Edge)
README.md
LICENSE
.gitignore
```

## 9. Implementation gates

The next session builds the kit with the sponsor one gate at a time. At each gate
Copilot writes the code, runs it against Azure, shows the evidence and waits for
approval.

| Gate | Work | Approval evidence |
|---|---|---|
| G0 | `LICENSE`, `.gitignore`, the README and three diagrams already exist (2026-10-26). Update `docs/decisions/0001-dev-workshop-boundaries.md` and `docs/glossary.md` to match this plan. | Search for customer names and customer systems finds nothing. |
| G1 | `Test-Prerequisites.ps1` and `deploy.ps1` with parameter prompts, defaults, the `.deploy/<team>.json` settings file, the quota check, S0 and the prompt logic. | S0 output on the sponsor's laptop with no parameters passed. Sponsor confirms the subscription and region shown. `n` stops the script. |
| G2 | S1 Bicep. | S1 checks and portal view. |
| G3 | S2 Bicep. | S2 checks and measured time. |
| G4 | S3 Bicep. | S3 checks. |
| G5 | API and web code, S4, `Test-Workflow.ps1`. | S4 checks and a manual walkthrough together. |
| G6 | Update the README, its three diagrams and their Status line to match the built kit, including real outputs, measured times and troubleshooting. Write `docs/production-readiness.md`. | Sponsor reads the README and the diagram screenshots. |
| G7 | Fresh S0 to S4 run with a new team name, then S5. Update the agenda with measured times. Commit and push. | Timings fit the agenda. All three groups are deleted. |

Risks to prove during the gates. If one fails, stop and decide together.

- PostgreSQL B1ms supports a private endpoint with Entra-only authentication in the region (G3).
- Bicep can set the API's system-assigned identity as PostgreSQL Entra admin from another resource group (G4).
- The web app reaches the API through the service endpoint, and the laptop gets 403 (G4, G5).
- App Service builds both Python apps within the S4 time budget (G5).

## 10. Done criteria

- A fresh S0 to S5 run works from a laptop that has only the documented prerequisites.
- Running both scripts with no parameters prompts for each value, and Enter accepts the defaults.
- Each stage stops at the prompt. `n` stops the run. A failure stops the run.
- The web app works from the internet. The API returns 403 from the internet.
  PostgreSQL has public access disabled and resolves to a private IP inside the VNet.
- No passwords or secrets appear in the repository, Bicep parameters, outputs or logs.
- The walkthrough works, and data survives a page refresh and an app restart.
- Running S1 to S4 again changes nothing and does not duplicate seed data.
- S5 deletes all three resource groups.
- The repository contains no customer names or customer material.
- Measured times fit the agenda.

## 11. Production follow-up

Gate G6 turns this table into `docs/production-readiness.md`.

| Area | Workshop shortcut | Production change |
|---|---|---|
| Access control | One runner with subscription Contributor. | RBAC per resource group: network team owns `rg-network`, DBAs own `rg-data`, app team owns `rg-app`. Deploy with scoped identities. |
| User identity | Anonymous personas. | Entra sign-in, server-enforced roles, site boundaries. |
| API network | Access restriction, public SCM site. | API private endpoint, private SCM and a deployment runner inside the VNet. |
| Ingress | App Service default domain. | Front Door or Application Gateway with WAF. |
| Database | API identity is the Entra admin. Tables created on startup. | Least-privilege roles, separate migration identity, versioned migrations, high availability, backups and tested restore. |
| Delivery | Laptop script with y/n prompts. | CI/CD with protected environments, required reviewers, what-if and artifact promotion. |
| Hosting | One B1 plan, single region. | Premium plan, zone redundancy, autoscale and a recovery plan. |
| Operations | Basic Application Insights. | Alerts, dashboards, budgets, runbooks and patching. |
| Business rules | Simplified shift, post and relief rules. | Approved labor, break and pay rules, signatures, corrections, payroll integration. |
| Testing | One scripted walkthrough. | Unit, integration, security and load tests. |
| Data | Synthetic records. | Data classification, privacy review and retention. |

## 12. References

- [App Service VNet integration](https://learn.microsoft.com/azure/app-service/overview-vnet-integration)
- [App Service access restrictions](https://learn.microsoft.com/azure/app-service/overview-access-restrictions)
- [PostgreSQL Flexible Server Private Link](https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private-link)
- [PostgreSQL Microsoft Entra authentication](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication)
- [Deploy files to App Service](https://learn.microsoft.com/azure/app-service/deploy-zip)
