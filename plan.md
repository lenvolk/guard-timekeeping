# Timekeeping workshop plan

Status: agreed on 2026-10-26, revised the same day after peer review. Implementation
starts in a new session and follows [section 9](#9-implementation-gates).

## 0. Rules for the implementing session

- This file is the source of truth. If `README.md`, `docs/decisions/` or
  `docs/glossary.md` disagree with it, follow this file and fix the other file in
  the gate that owns it.
- Work through gates G0 to G6 in order. At the end of each gate, show the evidence
  listed for it, stop and wait for the sponsor's approval. Do not start the next
  gate without it.
- Deploy only to the subscription the sponsor confirms at G1. Ask before any
  deletion other than S4 on a team the session created.
- After each approved gate, commit locally with a message naming the gate. Push
  only at G6, or earlier if the sponsor asks.
- Never read, copy or quote anything from folders outside this repository,
  including any sibling planning folder. The repository is public. Use only
  generic names and fictional people.
- Follow `.github/skills/unslop/SKILL.md` for all prose. Never use Mermaid. Draw
  diagrams with Excalidraw: preview them with the Excalidraw MCP server, then edit
  `tools/diagrams/render.mjs` and run it to write `docs/diagrams/*.excalidraw.svg`.
  Screenshot the result and check that no labels overlap.
- If a risk in section 9 fails, or a change would alter a decision in section 3,
  stop and ask. Do not quietly widen scope.

## 1. Summary

Attendees are new to Azure and do not need GitHub Copilot. In one four-hour
session, each team picks one person to run a PowerShell script on a laptop. The
script uses Bicep to deploy a three-tier timekeeping app: a web app, an API,
PostgreSQL and a storage account for guard signatures.

At the start the script asks for a deployment mode:

- **Human in the loop** (default). After each stage the script prints what it
  deployed and the check results, then waits for the runner to approve the next
  stage.
- **Autopilot**. One command deploys everything and runs all checks without
  pausing. It still stops on any failure.

The workshop uses public Azure endpoints with Entra ID identities instead of
passwords or keys. Private networking is a production change, documented but not
built.

The app is a proof of concept for a generic security-guard workforce. It uses
synthetic data only. It contains no customer names, customer documents or real
people.

Attendees learn:

- how resource groups split ownership of a multi-tier app
- how a web tier, an API tier, a database and blob storage connect in Azure
- how a managed identity replaces database passwords and storage keys
- how an Azure role assignment grants the API access to storage
- how Bicep deploys and redeploys resources
- where to find logs when something fails
- what must change before UAT or production

## 2. Requirements

| ID | Requirement |
|---|---|
| R1 | The session takes at most four hours and suits people new to Azure. |
| R2 | Bicep provisions all resources. No AKS. Attendees do not need GitHub Copilot. |
| R3 | DEV proof of concept with prepopulated synthetic data. |
| R4 | The web app is public. Backend services use public endpoints and accept only Entra ID identities, no passwords or keys. Private networking is documented as a production change. |
| R5 | At the start, the runner picks Human in the loop or Autopilot. Human in the loop pauses after each stage for approval. Autopilot runs every deployment stage without pausing. |
| R6 | One person per team runs the script on a local laptop. A prerequisite script checks the tools first. |
| R7 | The README gives step-by-step instructions with Excalidraw diagrams and follows the unslop rules. |
| R8 | Documentation lists what production needs, including private networking and RBAC per resource group. The workshop does not build it. |
| R9 | The repository is public. It must not contain customer names, customer material or real personal data. |
| R10 | Guards sign on the web app. The app stores each signature as an image in Azure Blob Storage and links it to the event. |
| R11 | Peer review asked for a fast path to a working end-to-end demo with health, seed, event, coverage and signature checks. Autopilot provides it. |

## 3. Decisions

| ID | Decision | Reason |
|---|---|---|
| D01 | Three tiers: a public web app, an API app, and a data tier with PostgreSQL Flexible Server and a storage account. | Shows a multi-tier app without extra services. |
| D02 | No VNet, private endpoints or private DNS in the workshop. PostgreSQL allows connections from Azure services only. The storage account allows public network access but rejects keys and anonymous reads. The API is reachable from the internet. | Peer review and the sponsor chose a working demo over network hardening. Production adds private networking (section 11). |
| D03 | The API's system-assigned managed identity is the PostgreSQL Entra administrator. Password authentication is off. | No database password exists. Production uses a least-privilege database role. |
| D04 | The storage account has shared key access and anonymous blob access turned off. Bicep grants the API's identity **Storage Blob Data Contributor** on the account, and the runner **Storage Blob Data Reader** so attendees can view signatures in the portal. | No storage key exists. Attendees see a real role assignment. |
| D05 | Because of D04, the runner needs **Owner** on the subscription, or **Contributor** plus **Role Based Access Control Administrator**. S0 checks and warns. | Contributor alone cannot create role assignments. |
| D06 | Each team gets two resource groups: `rg-<team>-data` (PostgreSQL, storage) and `rg-<team>-app` (App Service, monitoring). | Shows how production splits ownership. Production adds a network group. |
| D07 | On startup, the API creates its tables and loads seed data if the database is empty. No migration tool. | Keeps S3 to one code deployment. Production adds versioned migrations. |
| D08 | `deploy.ps1` asks for a mode at the start, or takes `-Mode Interactive` or `-Mode Autopilot`. Human in the loop prompts `Continue? (y/n)` after S0, S1, S2 and S3. Autopilot runs S0 to S3 without prompts. Cleanup (S4) never runs in Autopilot and always needs the typed team name. `-StartAt` resumes from a stage in either mode. | Gives a learning checkpoint per stage, or a single command for teams that fall behind. A checkpoint, not a security control. |
| D09 | The scripts run in Windows PowerShell 5.1 and PowerShell 7. The only required tool is the Azure CLI with Bicep. | App Service builds the Python code, so laptops need no Python or Docker. |
| D10 | Anonymous persona selection, with a "synthetic data" banner on every page. | No sign-in setup. Production adds Entra sign-in. |
| D11 | Python 3.12. FastAPI for the API. FastAPI with Jinja2 templates for the web app, which calls the API from the server. The signature pad is a small plain JavaScript file using an HTML canvas and pointer events, so it works with a mouse, pen or touch. The supervisor page reloads every 10 seconds. | One language and no JavaScript build step. |
| D12 | Signatures for the demo: the guard signs to start a shift, the relief guard signs to accept a post, and the guard signs to end a shift. The witness at shift start is selected by name and does not sign. | Three signatures show the feature without slowing the walkthrough. |
| D13 | Team name, subscription, region and team count are parameters with suggested defaults (section 6). If the runner omits one, the script asks and Enter accepts the default. Resource names include the team name and a short unique suffix. | The same repository works for a hackathon of any size or a single user. `eastus2` is the default because `eastus` often refuses new PostgreSQL Flexible servers. App, server and storage names must be globally unique. |
| D14 | Application Insights and Log Analytics in the app resource group. | Attendees need a place to look when something fails. |
| D15 | Cleanup deletes the team's two resource groups after the runner types the team name. | Stops charges. |
| D16 | MIT license. | The repository is public. |

The README and the GitHub repository description no longer name the customer.
Earlier commits stay as they are.

## 4. Architecture

[docs/diagrams/architecture.excalidraw.svg](docs/diagrams/architecture.excalidraw.svg)
shows this design. It has two resource-group zones. The browser calls the web app
in `rg-app`. The web app calls the API. The API's managed identity signs in to
PostgreSQL and to Blob Storage in `rg-data`. A dashed note marks private networking
as a production change.

Request path:

1. The browser calls the web app over HTTPS. Signature pads send a PNG image as a
   base64 form field.
2. The web app calls the API over HTTPS from the server.
3. The API connects to PostgreSQL on port 5432 with a token from its managed
   identity. The server's firewall rule allows Azure services only.
4. The API writes each signature to the `signatures` container with the same
   identity, then records the blob name on the event.

| Stage | Resource group | Resources |
|---|---|---|
| S1 | `rg-<team>-data` | PostgreSQL Flexible Server 16, Burstable B1ms, 32 GB, Entra authentication only, public access with the "allow Azure services" firewall rule. Database `timekeeping`. Storage account StorageV2, Standard_LRS, TLS 1.2, shared key access off, anonymous blob access off, private container `signatures`. |
| S2 | `rg-<team>-app` | Linux App Service plan B1. Web app and API app, Python 3.12, HTTPS only. The API has a system-assigned identity. A module scoped to `rg-data` makes it the PostgreSQL Entra admin and creates both storage role assignments. Log Analytics and Application Insights. App settings: `API_BASE_URL` on the web app, and `PGHOST`, `PGDATABASE`, `PGUSER`, `STORAGE_BLOB_URL` and `SIGNATURE_CONTAINER` on the API. |
| S3 | none | Zip `src/web` and `src/api`, deploy with `az webapp deploy`, wait for startup, then run the checks. |

Each stage template has `targetScope = 'subscription'`, creates its resource group
and finds earlier resources by name with `existing`. Any stage can therefore run
again on its own.

### Implementation notes

These details are easy to get wrong. Check each against current Microsoft Learn
documentation and Bicep schemas while building.

| Topic | Note |
|---|---|
| Naming | Every template computes `suffix = take(uniqueString(subscription().id, team), 5)` the same way. Names: `psql-<team>-<suffix>`, `st<team><suffix>` (storage: lowercase letters and digits only, 24 characters at most), `asp-<team>`, `app-<team>-web-<suffix>`, `app-<team>-api-<suffix>`, `log-<team>`, `appi-<team>`. |
| Deployments | `az deployment sub create --name tk-<team>-s<n> --location <loc>`. Each template outputs the names and hostnames the checks need. The script reads them with `az deployment sub show`. |
| PostgreSQL authentication | `authConfig`: Entra authentication enabled, password authentication disabled, so no administrator password parameter. S2 adds a `flexibleServers/administrators` child named with the API identity's object ID, `principalType: 'ServicePrincipal'` and `principalName` set to the API app name. The API's `PGUSER` is that app name. |
| PostgreSQL network | `network.publicNetworkAccess: 'Enabled'` and one firewall rule named `AllowAllAzureServicesAndResourcesWithinAzureIps` with start and end IP `0.0.0.0`. No rule for the laptop. |
| Storage account | `allowSharedKeyAccess: false`, `allowBlobPublicAccess: false`, `minimumTlsVersion: 'TLS1_2'`, `publicNetworkAccess: 'Enabled'`. Container `signatures` with `publicAccess: 'None'`. |
| Role assignments | Built-in role IDs: Storage Blob Data Contributor `ba92f5b4-2d11-453d-a403-e96b0029c9fe`, Storage Blob Data Reader `2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`. Scope both to the storage account. Name each with `guid(storage.id, principalId, roleId)` so a rerun changes nothing. `deploy.ps1` passes the runner's object ID and type (`User` or `ServicePrincipal`), read from `az ad signed-in-user show` or `az account show`. |
| Role propagation | New role assignments can take several minutes to apply. S3 checks retry the storage check for up to 5 minutes before failing. |
| API database connection | psycopg 3 with `sslmode=require`. Password is an access token from `DefaultAzureCredential` for scope `https://ossrdbms-aad.database.windows.net/.default`. Get a new token for each new connection, because tokens expire. |
| API storage access | `azure-storage-blob` `BlobServiceClient(STORAGE_BLOB_URL, credential=DefaultAzureCredential())`. Blob name `<site_id>/<yyyy>/<mm>/<dd>/<event_id>.png`, content type `image/png`. |
| Signature handling | The web page sends a PNG data URL. The API rejects a missing signature, a non-PNG header, or more than 200 KB. The page disables Submit until the guard draws a stroke. The API uploads the blob first, then commits the database transaction. If the commit fails, it deletes the blob. |
| Startup race | Gunicorn starts several workers and each runs startup code. Wrap table creation and seeding in `pg_advisory_lock` so only one worker seeds. Seed only when `guards` is empty. |
| App startup | Startup command `gunicorn -w 2 -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000 main:app`. App setting `SCM_DO_BUILD_DURING_DEPLOYMENT=true`, so App Service installs `requirements.txt`. |
| Telemetry | `APPLICATIONINSIGHTS_CONNECTION_STRING` app setting and `azure-monitor-opentelemetry` in both apps. |
| Zip files | Windows PowerShell 5.1 `Compress-Archive` can write backslashes in entry names, which break Linux deployments. Build zips with `System.IO.Compression.ZipFile` and forward-slash entry names. Leave out `__pycache__` and `.venv`. |
| CLI errors | Check `$LASTEXITCODE` after every `az` call and stop on failure. Never print tokens. |
| Seed data | Generic, made-up names only. Two sites in different US time zones, for example `America/New_York` and `America/Chicago`. Seed events have no signatures. |
| Web form routes | `POST /guard/{id}/start-shift`, `/guard/{id}/take-post`, `/assignment/{id}/relieve`, `/guard/{id}/end-shift`. Signature fields are named `signature`. `Test-Workflow.ps1` posts a small generated PNG to these routes and checks the resulting page or status code. |

## 5. Application scope

### Walkthrough

1. Open the web URL and see the synthetic-data banner.
2. Pick a site and a guard persona.
3. Start a shift. Pick a different guard as witness, confirm "equipment on" and
   sign.
4. Take a vacant post.
5. Try to hand the post to a guard who is already on another post and see the
   rejection. Then hand it to an available relief guard, who signs to accept.
6. The original guard is still on shift but off post. Confirm "equipment off",
   sign and end the shift.
7. Open the supervisor board. It shows covered and vacant posts, guards on shift
   and recent events with signature thumbnails.
8. In the Azure portal, open the storage account's `signatures` container and see
   the same PNG files.
9. Refresh the page. The data is still there.

### Data

Seed data has 2 sites, 4 posts (2 per site) and 12 fictional guards. Some guards
start on shift so relief has an available candidate and a busy one.

Tables: `sites`, `posts`, `guards`, `shifts`, `post_assignments`, `events`.
`events` has nullable `signed_by_guard_id` and `signature_blob` columns.
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
- Starting a shift, accepting relief and ending a shift each need a signature.
- Each successful action writes one event in the same transaction.
- The server stores UTC timestamps. Pages show the site's time zone.
- Signatures are images for the demo. They are not legally binding.

### API and pages

API: `GET /healthz`, `GET /status` (database, storage and seed counts),
`GET /sites`, `GET /sites/{id}/board`, `GET /guards/{id}`, `POST /shifts`,
`POST /shifts/{id}/end`, `POST /assignments`, `POST /assignments/{id}/relieve`,
`GET /events?site_id=`, `GET /events/{id}/signature` (streams the PNG).

Web pages: `/` (pick site and guard), `/guard/{id}`, `/supervisor/{site_id}`,
`/signature/{event_id}` (proxies the PNG from the API), `/status` (shows whether
the API, database and storage respond, and the seed counts).

### Out of scope

Sign-in, legally binding signatures, breaks and lunch, payroll, notifications,
offline use, staffing recommendations, corrections, private networking,
multi-region recovery, attendee code changes and a unit test suite. The scripted
walkthrough in S3 is the only automated app test.

## 6. Scripts and stages

```powershell
.\scripts\Test-Prerequisites.ps1          # optional: -Location -TeamCount
.\deploy.ps1                              # optional: -Mode -Team -SubscriptionId -Location -StartAt
```

| Parameter | Script | Suggested default | Notes |
|---|---|---|---|
| `-Mode` | `deploy.ps1` | `Interactive` | `Interactive` (human in the loop) or `Autopilot`. Not saved, so each run asks again. |
| `-Team` | `deploy.ps1` | `team01` | Lowercase letters and digits, 3 to 10 characters. Used in resource group and resource names. |
| `-SubscriptionId` | both | The current `az account show` subscription | The script prints the name and ID before using it. |
| `-Location` | both | `eastus2` | S0 checks that the region offers PostgreSQL B1ms and App Service B1. |
| `-TeamCount` | `Test-Prerequisites.ps1` | `1` | The facilitator sets the hackathon size. The script checks regional quota for that many teams. |
| `-StartAt` | `deploy.ps1` | `S0` | Resumes from a later stage. `-StartAt S4` runs cleanup only. |

The script first asks:

```text
Deployment mode
  [1] Human in the loop: pause after each stage for your approval (default)
  [2] Autopilot: deploy everything, stop only on failure
Choose [1]:
```

When another parameter is missing, the script prompts with the default in
brackets, for example `Region [eastus2]:`. It saves the team, subscription and
region to `.deploy/<team>.json`, which git ignores, so a resumed run with `-Team`
uses the same values.

For each stage, `deploy.ps1` prints the stage name and target resource group,
deploys, runs the stage checks and prints the results. In Human in the loop mode
it then asks `Review the results above. Continue to <next stage>? (y/n)`. Answering
`n` stops and prints the resume command. In Autopilot mode it prints the results
and continues. In both modes, a failed deployment or check stops the script and
prints the error and the resume command. At the end, both modes print the web
URL and a summary of every check.

| Stage | Action | Checks the script prints | Estimate |
|---|---|---|---|
| S0 | Preflight. Deploys nothing. | Azure CLI and Bicep versions, signed-in account, subscription, providers registered, PostgreSQL B1ms offered in the region, runner has a role that can create role assignments (warning only). | 1 min |
| S1 | Data tier | Resource group. PostgreSQL state Ready, password authentication Disabled, firewall rule. Storage account shared key access Disabled, container `signatures` exists. | 10 to 15 min |
| S2 | App tier | Resource group. Both apps Running. API identity listed as PostgreSQL admin. Two storage role assignments. Application Insights. | 5 min |
| S3 | Code | Web `/healthz` returns 200. `/status` shows the database and storage respond, with 2 sites, 4 posts and 12 guards. `scripts/Test-Workflow.ps1` starts a shift with a signature, takes a post, gets one rejected relief, completes a relief with a signature, ends the shift with a signature, checks post coverage on the supervisor board and reads one signature back. | 5 to 10 min |
| S4 | Cleanup. Never runs in Autopilot. | Asks for the team name, deletes both groups and reports progress. | 10 min, runs in Azure |

Gates G2 to G6 replace these estimates with measured times.

### Before the event

Each runner needs:

- Windows PowerShell 5.1 or PowerShell 7
- Azure CLI with Bicep (`az bicep install`). G1 sets the minimum version.
- git, or the repository downloaded as a zip
- Owner on the workshop subscription, or Contributor plus Role Based Access
  Control Administrator
- network access to Azure and `*.scm.azurewebsites.net` through any corporate proxy

The facilitator:

- picks the subscription and region, or accepts the defaults
- runs `Test-Prerequisites.ps1 -TeamCount <n>` to check quota (one B1 plan, one
  B1ms server and one storage account per team) and register `Microsoft.Web`,
  `Microsoft.DBforPostgreSQL`, `Microsoft.Storage`, `Microsoft.Insights` and
  `Microsoft.OperationalInsights`
- hands out team names, for example `team01` to `team05`

A single person trying the kit alone runs both scripts with no parameters.

## 7. Agenda

| Time | Minutes | Activity |
|---|---:|---|
| 00:00-00:20 | 20 | App and architecture overview. Run `Test-Prerequisites.ps1`, choose Human in the loop, run S0. |
| 00:20-01:00 | 40 | S1. Break while PostgreSQL provisions. Explore PostgreSQL authentication and the storage account settings. Approve. |
| 01:00-01:35 | 35 | S2. Explore the apps, managed identity, role assignments and Application Insights. Approve. |
| 01:35-02:05 | 30 | S3. Deploy code and read the checks. Approve. |
| 02:05-02:50 | 45 | Walkthrough as guard and supervisor, with signatures. Find the PNGs in the storage account and the requests in Application Insights. |
| 02:50-03:30 | 40 | Production gaps: private networking, RBAC per resource group, sign-in and the rest of section 11. |
| 03:30-03:45 | 15 | S4 cleanup. |
| 03:45-04:00 | 15 | Buffer and questions. |

If a team falls behind, it reruns with `-Mode Autopilot -StartAt <stage>` to catch
up. If Azure itself is slow, the facilitator shows the remaining steps on a
prepared deployment and says it is a demonstration.

## 8. Repository layout

```text
deploy.ps1
scripts/Test-Prerequisites.ps1
scripts/Test-Workflow.ps1
infra/s1-data.bicep
infra/s2-app.bicep
infra/modules/
src/api/        FastAPI app, schema.sql, seed data, requirements.txt
src/web/        FastAPI + Jinja2 app, templates, signature pad JS, CSS, requirements.txt
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
| G0 | `LICENSE`, `.gitignore`, the README and three diagrams already exist. Update `docs/decisions/0001-dev-workshop-boundaries.md` and `docs/glossary.md` to match this plan. | Search for customer names and customer systems finds nothing. |
| G1 | `Test-Prerequisites.ps1` and `deploy.ps1` with the mode prompt, parameter prompts, defaults, the `.deploy/<team>.json` settings file, the quota and role checks, S0, the stage loop and S4. | S0 output with no parameters passed. Sponsor confirms the subscription and region. `n` stops the script. Autopilot does not prompt. |
| G2 | S1 Bicep. | S1 checks, portal view and measured time. |
| G3 | S2 Bicep. | S2 checks and portal view of the role assignments. |
| G4 | API and web code, S3, `Test-Workflow.ps1`. | S3 checks and a manual walkthrough together, including signatures in the portal. |
| G5 | Update the README, its three diagrams and the Status line to match the built kit, with real outputs, measured times and troubleshooting. Write `docs/production-readiness.md`. | Sponsor reads the README and the diagram screenshots. |
| G6 | Fresh run in Autopilot with a new team name, then S4. Update the agenda with measured times. Commit and push. | Timings fit the agenda. Both groups are deleted. |

Risks to prove during the gates. If one fails, stop and decide together.

- Bicep can set the API's identity as PostgreSQL Entra admin and create storage role assignments from the app stage, across resource groups (G3).
- The runner's account can create role assignments. If not, S2 fails with a clear message (G1, G3).
- Role assignments apply within the 5-minute retry window (G4).
- App Service builds both Python apps within the S3 time budget (G4).

## 10. Done criteria

- A fresh Autopilot run and a fresh Human in the loop run both work from a laptop
  that has only the documented prerequisites.
- Running both scripts with no parameters prompts for each value, and Enter accepts
  the defaults.
- Human in the loop stops at each prompt and `n` stops the run. Autopilot never
  prompts until cleanup. A failure stops the run in both modes.
- The web app works from the internet. Signatures appear on the supervisor board
  and in the storage container.
- PostgreSQL rejects password sign-in. The storage account rejects key access.
- No passwords, keys or secrets appear in the repository, Bicep parameters,
  outputs or logs.
- The walkthrough works, and data survives a page refresh and an app restart.
- Running S1 to S3 again changes nothing and does not duplicate seed data.
- S4 deletes both resource groups.
- The repository contains no customer names or customer material.
- Measured times fit the agenda.

## 11. Production follow-up

Gate G5 turns this table into `docs/production-readiness.md`.

| Area | Workshop shortcut | Production change |
|---|---|---|
| Network | Public endpoints. PostgreSQL allows any Azure service. The API is open to the internet. | VNet with App Service integration, private endpoints for PostgreSQL, Storage and the API, private DNS, and a deployment runner inside the VNet. |
| Access control | One runner with Owner on the subscription. | RBAC per resource group: network team owns `rg-network`, DBAs own `rg-data`, app team owns `rg-app`. Deploy with scoped identities. |
| User identity | Anonymous personas. | Entra sign-in, server-enforced roles, site boundaries. |
| Ingress | App Service default domain. | Front Door or Application Gateway with WAF. |
| Database | API identity is the Entra admin. Tables created on startup. | Least-privilege roles, separate migration identity, versioned migrations, high availability, backups and tested restore. |
| Signatures | PNG images, no legal standing. Runner can read them. | Approved e-signature requirements, retention, immutable storage, access auditing and least-privilege readers. |
| Delivery | Laptop script with y/n prompts or Autopilot. | CI/CD with protected environments, required reviewers, what-if and artifact promotion. |
| Hosting | One B1 plan, single region. | Premium plan, zone redundancy, autoscale and a recovery plan. |
| Operations | Basic Application Insights. | Alerts, dashboards, budgets, runbooks and patching. |
| Business rules | Simplified shift, post and relief rules. | Approved labor, break and pay rules, corrections, payroll integration. |
| Testing | One scripted walkthrough. | Unit, integration, security and load tests. |
| Data | Synthetic records. | Data classification, privacy review and retention. |

## 12. References

- [PostgreSQL Microsoft Entra authentication](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication)
- [PostgreSQL firewall rules](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-firewall-rules)
- [Prevent Shared Key authorization for a storage account](https://learn.microsoft.com/azure/storage/common/shared-key-authorization-prevent)
- [Assign Azure roles with Bicep](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-template)
- [Deploy files to App Service](https://learn.microsoft.com/azure/app-service/deploy-zip)
- [App Service VNet integration](https://learn.microsoft.com/azure/app-service/overview-vnet-integration) (production)
- [PostgreSQL Private Link](https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private-link) (production)
