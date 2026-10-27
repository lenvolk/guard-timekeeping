# Demo: test the timekeeping app

Use this after `deploy.ps1` has finished. It walks through the whole transaction
chain: **identify, transact, sign, supervise, audit**. Allow about 20 minutes.

`deploy.ps1` works in numbered stages, and the console prints a header for each
one, for example `=== S3 Code ===`. This guide refers to them by number:

| Stage | What it does |
|---|---|
| S0 | Checks your tools, sign-in, region and quota. Deploys nothing |
| S1 | Creates `rg-<team>-data`: PostgreSQL and the storage account |
| S2 | Creates `rg-<team>-app`: the web and API apps, the VNet, the private endpoint and the role assignments |
| S3 | Uploads the app code, runs the end-to-end checks and prints the website address |
| S4 | Cleanup. Deletes both resource groups. It runs only when you ask for it |

`-StartAt` reruns from one stage, for example `.\deploy.ps1 -Team team01 -StartAt S2`.

![How to test: automatic checks, the status page, a guard walkthrough with a lunch break, then a supervisor approval and the daily record](docs/diagrams/test-flow.excalidraw.svg)

## What you are testing

| Step | What the app does | You see it work when |
|---|---|---|
| Identify | Sign-in with employee ID and date of birth. Guards and supervisors see different pages | A wrong date of birth is refused, and a guard cannot open the supervisor pages |
| Transact | Start and end a shift, take a post, take a lunch or restroom break, hand over a post | Each step changes the guard's badge, and steps out of order are refused |
| Sign | A finger or stylus signature on every step that changes responsibility | Each signature shows who signed, when and what it means |
| Supervise | Corrections need a reason and a supervisor's approval. Overdue breaks and long shifts are flagged | The correction waits under **Needs attention** until approved |
| Audit | A daily record per site, with original and corrected times, printable and as CSV | The record shows both times and every signature as **Verified** |

`<team>` is the team name you gave `deploy.ps1`, for example `team01`.

## Find your web address

S3 prints it at the end of the deployment, for example
`Website: https://app-team01-web-abcde.azurewebsites.net`. If you lost it, run:

```powershell
az webapp list --resource-group rg-team01-app --query "[].defaultHostName" -o tsv
```

The name with `-web-` is the site you open. The `-api-` app only answers the web app.

## Sign-in details

All names and dates are synthetic. Type the date as **MM/DD/YYYY**. The ID is not
case-sensitive and the dash is optional, so `g1001` works too.

**Riverside Office Park** (site 1, used in the walkthrough)

| Employee ID | Name | Date of birth | Starts as |
|---|---|---|---|
| G-1001 | Jordan Avila | 03/14/1988 | Off shift |
| G-1002 | Priya Hollis | 07/22/1991 | On post: Main Gate |
| G-1003 | Marcus Ferrin | 11/05/1985 | Available |
| G-1004 | Elena Brandt | 01/30/1993 | Off shift |
| G-1005 | Tomas Reyna | 09/09/1979 | Off shift |
| G-1006 | Grace Okafor | 05/17/1996 | Off shift |

**Lakeshore Distribution Center** (site 2, used by the automatic test)

| Employee ID | Name | Date of birth | Starts as |
|---|---|---|---|
| G-2001 | Dana Whitlock | 12/02/1987 | Off shift |
| G-2002 | Samuel Ortiz-Lane | 04/26/1990 | On post: North Dock Gate |
| G-2003 | Keisha Morrow | 08/11/1984 | Available |
| G-2004 | Victor Lindqvist | 02/19/1992 | Off shift |
| G-2005 | Hannah Prescott | 10/03/1995 | Off shift |
| G-2006 | Omar Castellano | 06/28/1982 | Off shift |

**Supervisors**

| Employee ID | Name | Date of birth | Sees |
|---|---|---|---|
| S-1001 | Riley Chen | 04/04/1980 | Riverside Office Park |
| S-2001 | Morgan Patel | 10/10/1983 | Lakeshore Distribution Center |
| S-9001 | Avery Brooks | 01/15/1976 | Both sites (regional) |

Five wrong tries lock an ID for five minutes, and the supervisor sees it under
**Needs attention**. A guard is signed out after 2 minutes without activity, so a
shared tablet never stays signed in. A supervisor is signed out after 15 minutes.

## A. Automatic checks

S3 already ran these. Every line should say `[PASS]`. `Test-Workflow.ps1` signs in
as each person and runs the whole chain on Lakeshore, so Riverside stays as it
was for your walkthrough:

```powershell
.\scripts\Test-Workflow.ps1 -WebUrl https://app-team01-web-abcde.azurewebsites.net
```

## B. Status page

Open `https://<your web address>/status`. It needs no sign-in. Every row should
say **ok**: web app, API, database (signed in with the API's managed identity) and
signature storage (reached through the private endpoint).

## C. Guard walkthrough on a tablet

Use **Riverside Office Park**. A tablet, or a browser window about 1000 pixels
wide, shows the layout the guards would use. Each signature box needs a drawing
with a finger, pen or mouse. The submit button stays grey until you sign.

1. **Sign in.** Employee ID `G-1001`, date of birth `03/14/1988`.
   You see: Jordan Avila's page, **Off shift**.
2. **Start a shift.** Pick any other guard as the witness, tick **Equipment on**,
   sign, then click **Start shift**.
   You see: *Shift started.* The badge changes to **Available**.
3. **Take a post.** Choose **Lobby Desk**, then click **Take post**.
   You see: **On post**.
4. **Take a lunch break.** Under *Take a break*, pick **Lunch, 60 minutes** and
   cover guard **Marcus Ferrin**. Marcus types his date of birth, `11/05/1985`, and
   signs to accept the post. Click **Start break**.
   You see: **On lunch break**, due back in 60 minutes, Marcus covering Lobby Desk.
   Marcus can't hand the post away or end his shift until Jordan returns.
5. **Return from the break.** Jordan signs, then clicks **Return from break**.
   You see: *Welcome back.* Jordan is **On post** again and Marcus is **Available**.
6. **Hand over the post.** Under *Hand over Lobby Desk*, pick **Marcus Ferrin**.
   Marcus types `11/05/1985` and signs. Click **Hand over post**.
   You see: *Post handed over to the relief guard.*
7. **End the shift.** Tick **Equipment off**, sign, then click **End shift**.
   You see: *Shift ended.* Jordan is **Off shift**.
8. **Request a correction.** Under *Recent activity*, find *ended a shift* and
   click **Request a correction**. Enter a time a few minutes earlier and a reason,
   for example *I left at 17:00, the tablet was busy*. Click **Send to supervisor**.
   You see: the entry marked *correction waiting for approval*.
9. **Sign out** (top right).

A restroom break works the same way, with 15 minutes instead of 60.

## D. Supervisor review and audit

1. **Sign in** as `S-1001`, date of birth `04/04/1980`.
   You see: the Riverside supervisor board, which refreshes every 10 seconds.
2. **Needs attention.** Jordan's correction is listed with the original time, the
   new time and the reason. Type a note if you like and click **Approve**.
   Rejecting needs a note.
3. **Posts and guards.** Lobby Desk is covered by Marcus, and Jordan is off shift.
   A guard on a break shows as **On break**, and the guard covering shows as
   **Covering**. An overdue break turns red here.
4. **Daily record.** Click **Daily record** in the top bar.
   You see: every entry of the day. The corrected entry shows the new time, with
   the recorded time crossed out next to it, the reason and who approved it.
   Every signature shows the signer, time and meaning, for example
   *Responsibility: accepts Lobby Desk*, and **Verified**. That means the image still
   matches the fingerprint (SHA-256) saved when it was signed.
5. **Export CSV** downloads the same record. **Print** gives a clean paper copy.

### Try the rules (optional)

Each of these is refused with a message and saves nothing:

- Sign in with a wrong date of birth. After five tries the ID locks for five minutes.
- As a guard, open `/supervisor/1` in the address bar: *This page is for supervisors.*
- Start a break and type the cover guard's date of birth wrong.
- On a post, try **End shift**: *Hand the post to a relief guard before ending the shift.*
- As a supervisor, click **Reject** without a note.

## Start over with Reset

Signed in as a supervisor, click **Reset** in the top bar, then **Reset demo data**.
Everything recorded at both sites is deleted and the synthetic data is loaded
again, so every badge is back to the tables above. Everyone is signed out.
Deleted signature files stay recoverable for 7 days (soft delete).

Without Reset, posts stay covered after the first walkthrough. You can still
practice a break or a hand-over with any guard who is **On post** and a guard who
is **Available**.

## See the data in the Azure portal (optional)

1. Go to <https://portal.azure.com> and sign in with the account that ran
   `deploy.ps1`.
2. Open **Resource groups**, then `rg-<team>-data`, then the storage account
   `st<team>…`.
3. Open **Data storage**, then **Containers**, then `signatures`. Files are stored
   as `<site>/<year>/<month>/<day>/<event>.png`.

If the portal says access from your network is blocked, a subscription policy has
turned off public network access on the storage account. That is expected: only
the API can reach storage, through the private endpoint. Use the daily record.

To watch requests as you click, open `rg-<team>-app`, then `appi-<team>`, then
**Live metrics**.

## If something is wrong

| What you see | Likely cause | What to do |
|---|---|---|
| The site does not load, or returns 503, right after S3 | The apps are still starting | Wait 2 to 3 minutes and refresh |
| Every page says *The database is not available*, on a deployment that worked before | The PostgreSQL server is **Stopped**. Some subscriptions stop idle servers overnight | Open **Status**. It says *The database server is stopped*. Select **Start database**, which needs no sign-in, and wait about 2 minutes |
| *The employee ID or date of birth is wrong* | A typo, or the date is not MM/DD/YYYY | Check the tables above |
| *Too many wrong tries* | Five wrong tries locked the ID | Wait five minutes |
| You are back on the sign-in page | 2 minutes without activity signed you out | Sign in again |
| `/status` says storage **error** | The storage role is still being applied | Wait 5 minutes. If it stays, run `.\deploy.ps1 -Team <team> -StartAt S2` |
| `/status` says database **error** right after a deployment | The API identity is not the PostgreSQL admin yet | Run `.\deploy.ps1 -Team <team> -StartAt S2` |
| No guard to pick as cover or relief | Nobody at the site is **Available** | Sign in as an off-shift guard and start a shift first |

## Let Copilot drive the browser (optional)

If you set up the `playwright` MCP server from the README, you can ask GitHub
Copilot to run parts C and D for you, for example:

> Open `<your web address>` at tablet size. Follow parts C and D of demo.md with
> the sign-in details there, then confirm the daily record shows the corrected
> entry and every signature as Verified.
