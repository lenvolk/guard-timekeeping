# Decision 0001: DEV workshop boundaries

Date: 2026-10-26

Status: Constraints confirmed by the workshop sponsor. Architecture and
implementation remain pending.

## Context

The audience is new to Azure. The workshop must fit within four hours. The
customer's reference deck describes a longer event and a broader timekeeping
system. The reference architecture images include services and integrations that
would add setup and troubleshooting work.

The sponsor's current answers specify a DEV proof of concept, synthetic data,
a public frontend, private backend endpoints, new application and infrastructure
code, and staged deployment with human approval.

## Confirmed decisions

1. Use Bicep to provision the workshop infrastructure. Do not use AKS.
2. Build a new timekeeping application and infrastructure rather than present
   either reference repository as the finished solution.
3. Prepopulate synthetic data. Do not use real personnel or payroll records.
4. Expose the frontend publicly and use private endpoints for the backend.
5. Stop after deployment stages for validation and explicit human approval.
   Do not continue automatically because a provisioning command succeeded.
6. Document the workshop in the README with focused diagrams and plain language.
7. Treat UAT and production as later customer work. Document gaps rather than
   claim that the workshop deployment is production-ready.

## Consequences

- A private API cannot be called directly by a browser without private-network
  connectivity. A public server-side frontend can forward allowed requests.
- App Service VNet integration provides outbound connectivity. A private endpoint
  provides inbound private access. The design may need both.
- A private API's code-deployment endpoint and a private database need a reachable
  deployment and migration execution path.
- Private networking does not establish a user's identity or enforce business
  permissions.
- Infrastructure, application code, migrations and seed data are distinct
  deployment responsibilities.
- Four-hour feasibility requires a rehearsal. Live generation of all code and
  infrastructure from an empty repository has not been accepted as a timed promise.
- The initial foundation is an application environment, not an enterprise landing
  zone with organization-wide governance.

## Open decisions

| Decision | Why it matters |
|---|---|
| Separate private API versus private data services only | Changes the hosting topology and deployment path. |
| Anonymous demo personas versus authenticated access | Public reachability does not settle access control. |
| Facilitator preparation versus live from-scratch authoring | Determines whether a four-hour agenda is credible. |
| Local stage commands versus GitHub Actions approval gates | Changes approval enforcement and prerequisites. |
| Azure commercial versus government cloud | Changes endpoints, service availability and identity setup. |
| Shared environment versus one environment per team | Changes permissions, resource naming and cost. |
| Spending limit | Constrains service tiers, environment count and lifetime. |

Decisions about deployment runners, database bootstrap, application language,
exercise details and exact timing follow the relevant choices above.

## Evidence

- Workshop sponsor's answers on 2026-10-26.
- Read-only review of the meeting notes, the 18-slide customer deck and four
  architecture PNGs in the sibling Planning directory.
- Read-only review of the sibling FastAPI/PostgreSQL sample and PostgreSQL
  workshop repositories.

The meeting notes state that the meeting was not transcribed. Proposed
architectures in those materials are not evidence of customer approval or an
existing deployment. Internal references are not copied into this public repository.
