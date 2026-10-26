# Workshop glossary

These terms keep infrastructure and business discussions consistent. Definitions
from the customer references do not by themselves approve workshop scope or
establish payroll policy.

| Term | Meaning in this workshop |
|---|---|
| DEV proof of concept | A learning deployment using synthetic data. It is not approved for production operations or payroll. |
| Synthetic data | Invented guards, sites, posts and time records. Do not substitute anonymized real records without a separate decision. |
| Public frontend | A web entry point reachable from the internet. This does not specify whether sign-in is required. |
| Backend | The API and data services behind the frontend. The exact private-endpoint boundary is still being decided. |
| Private endpoint | A private IP connection to a supported Azure service through Private Link. Public access must be explicitly configured separately. |
| VNet integration | For App Service, outbound connectivity from the app into a virtual network. It is not an inbound private endpoint. |
| Private DNS | Name resolution that maps service hostnames to private endpoint addresses for connected clients. |
| Frontend server | Server-side web code that serves the UI and makes allowed requests to the private API. The browser itself does not gain VNet access. |
| Environment foundation | Network, DNS and initial identities and role assignments for this application environment. It is not a complete enterprise landing zone. |
| Deployment stage | A bounded deployment operation followed by checks and evidence. |
| Approval gate | An explicit human decision permitting the next stage after reviewing the preceding results. |
| Migration | A versioned database schema change. Bicep resource deployment does not perform it automatically. |
| Seed data | A repeatable set of synthetic records that makes the deployed demo usable. |
| Shift | The guard's overall work interval. The customer flow separates final shift sign-off from leaving a post. Pay rules remain a separate decision. |
| Post assignment | A period during a shift when a guard covers a specific post. Ending a post assignment does not necessarily end the shift. |
| Relief | Another guard taking responsibility for post coverage so the assigned guard can leave the post. Exact eligibility rules remain open. |
| Witness acknowledgment | A second person's acknowledgment required by parts of the proposed customer flow. A demo persona is not proof of a second authenticated person. |
| Correction | An explicit change to a recorded event with its reason and history retained. Workshop behavior and approval policy still need definition. |
| UAT | User acceptance testing against agreed requirements in a separately configured environment. |

Update this glossary and the [decision record](decisions/0001-dev-workshop-boundaries.md)
when the interview settles a term or changes its meaning.
