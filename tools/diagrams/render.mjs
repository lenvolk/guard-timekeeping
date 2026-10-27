import { chromium } from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Renders the README diagrams with the Excalidraw library in headless Microsoft Edge.
// Usage: npm install, then node render.mjs [architecture|deployment-stages|production-rbac|test-flow|pilot-path]
const outDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../docs/diagrams');
const only = process.argv[2];

// ---------- helpers (Excalidraw element skeletons) ----------
const box = (id, x, y, w, h, text, bg, o = {}) => ({
  type: 'rectangle', id, x, y, width: w, height: h,
  backgroundColor: bg, fillStyle: 'solid', roundness: { type: 3 },
  strokeColor: o.stroke ?? '#1e1e1e', strokeWidth: o.sw ?? 2,
  strokeStyle: o.dash ? 'dashed' : 'solid', opacity: o.opacity ?? 100,
  ...(text ? { label: { text, fontSize: o.fs ?? 20, strokeColor: o.color ?? '#1e1e1e' } } : {}),
});
const zone = (id, x, y, w, h, bg, stroke) => box(id, x, y, w, h, null, bg, { stroke, dash: true, sw: 2 });
const caption = (id, x, y, w, h, text, fs = 18, color = '#1e1e1e') => ({
  type: 'rectangle', id, x, y, width: w, height: h,
  strokeColor: 'transparent', backgroundColor: 'transparent',
  label: { text, fontSize: fs, strokeColor: color },
});
const text = (id, x, y, t, fs = 20, color = '#1e1e1e') => ({
  type: 'text', id, x, y, text: t, fontSize: fs, strokeColor: color,
});
const arrow = (id, x, y, pts, o = {}) => ({
  type: 'arrow', id, x, y, width: 1, height: 1, points: pts,
  strokeColor: o.color ?? '#1e1e1e', strokeWidth: o.sw ?? 2,
  strokeStyle: o.dash ? 'dashed' : 'solid',
  endArrowhead: o.end === undefined ? 'arrow' : o.end,
  startArrowhead: o.start ?? null,
  ...(o.label ? { label: { text: o.label, fontSize: o.fs ?? 16, strokeColor: o.color ?? '#1e1e1e' } } : {}),
});

// ---------- diagram 1: architecture ----------
const architecture = [
  text('title', 40, 0, 'What each team deploys', 32),

  box('browser', 40, 160, 170, 100, 'Tablet or browser\nsign in: ID +\ndate of birth', '#ffec99', { fs: 16 }),

  zone('zapp', 260, 90, 590, 560, '#e7f5ff', '#1971c2'),
  text('zappt', 280, 102, 'rg-<team>-app', 20, '#1971c2'),
  box('web', 290, 160, 240, 100, 'Web app\nsign-in, roles,\nsignature pad', '#a5d8ff', { fs: 18 }),
  box('api', 570, 160, 250, 100, 'API app\nrules, audit trail\nmanaged identity', '#d0bfff', { fs: 18 }),
  box('appi', 290, 320, 240, 90, 'Application Insights\n+ Log Analytics', '#eebefa', { fs: 18 }),
  box('dns', 290, 470, 240, 120, 'Private DNS zone\nprivatelink.blob...\nstorage name -> 10.42.0.x', '#f8f9fa', { fs: 16 }),

  zone('zvnet', 555, 300, 280, 330, '#f3f0ff', '#7048e8'),
  text('zvnett', 575, 606, 'vnet-<team> 10.42.0.0/24', 14, '#7048e8'),
  box('snet', 575, 350, 240, 90, 'snet-app\nAPI VNet integration', '#e5dbff', { fs: 18 }),
  box('pe', 575, 510, 240, 90, 'snet-pe\nBlob private endpoint', '#e5dbff', { fs: 18 }),
  arrow('a_dns', 530, 530, [[0, 0], [25, 0]], { dash: true, end: null, color: '#7048e8' }),
  caption('l_dns', 290, 596, 240, 24, 'linked to the VNet', 14, '#7048e8'),

  zone('zdata', 1040, 90, 340, 560, '#ebfbee', '#2f9e44'),
  text('zdatat', 1060, 102, 'rg-<team>-data', 20, '#2f9e44'),
  box('pg', 1070, 160, 280, 100, 'PostgreSQL B1ms\nEntra sign-in only', '#b2f2bb', { fs: 18 }),
  box('st', 1070, 510, 280, 90, 'Storage account\nsignatures/*.png', '#c3fae8', { fs: 18 }),

  arrow('a_bw', 210, 210, [[0, 0], [80, 0]]),
  caption('l_bw', 210, 186, 48, 20, 'HTTPS', 13),
  arrow('a_wa', 530, 210, [[0, 0], [40, 0]]),
  caption('l_wa', 495, 266, 110, 34, 'shared key +\nsigned-in person', 12),
  arrow('a_snet', 695, 260, [[0, 0], [0, 90]], { color: '#7048e8' }),
  arrow('a_pe', 695, 440, [[0, 0], [0, 70]], { color: '#7048e8' }),
  arrow('a_pg', 820, 210, [[0, 0], [250, 0]]),
  caption('l_pg', 850, 140, 180, 60, 'SQL + Entra token\nPostgreSQL admin\npublic endpoint', 14),
  arrow('a_st', 815, 555, [[0, 0], [255, 0]], { color: '#7048e8' }),
  caption('l_st', 840, 490, 210, 60, 'writes + reads PNGs\nBlob Data Contributor\nprivate IP only', 14, '#7048e8'),

  box('runner', 1070, 730, 280, 80, 'Workshop runner (you)\nin the Azure portal', '#ffec99', { fs: 18 }),
  arrow('a_rs', 1210, 730, [[0, 0], [0, -130]], { dash: true, color: '#e03131' }),
  caption('l_rs', 1215, 650, 190, 60, 'Blob Data Reader\nblocked if a policy turns\npublic access off', 14, '#e03131'),

  box('prod', 40, 730, 980, 70, 'Production adds: Entra ID sign-in, private endpoints for PostgreSQL and the API, 10-year immutable retention, a WAF', '#fff9db', { fs: 16, dash: true, stroke: '#f08c00' }),
  caption('legend', 40, 830, 1340, 50, 'People sign in with employee ID and date of birth (stored only as a salted hash). Only the web app can call the API.\nBlob Storage is reached only through the private endpoint. Azure services check Entra ID identities, never a password or key.', 16, '#495057'),
];

// ---------- diagram 4: how to test (demo.md) ----------
const SW = 172, SG = 25;
const steps = [
  ['s1', '1  Sign in\nG-1001\nJordan Avila', 'ID + date of birth'],
  ['s2', '2  Start shift\nwitness +\nsignature', 'Off shift ->\nAvailable'],
  ['s3', '3  Take post\nLobby Desk', 'Available ->\nOn post'],
  ['s4', '4  Lunch break\nMarcus covers:\nDOB + signs', 'Jordan On break\nMarcus Covering'],
  ['s5', '5  Return\nfrom break\nsignature', 'Jordan On post\nMarcus Available'],
  ['s6', '6  Hand over\nto Marcus:\nDOB + signs', 'Marcus On post\nJordan Available'],
  ['s7', '7  End shift\n+ request a\ncorrection', 'Off shift,\ncorrection waiting'],
];
const sup = [
  ['u1', '8  Sign in\nS-1001\nRiley Chen', 'supervisor of\nRiverside'],
  ['u2', '9  Needs attention\napprove the\ncorrection', 'reason + decision\nrecorded'],
  ['u3', '10  Daily record\noriginal + corrected,\nVerified, CSV', 'nothing recorded\nis ever changed'],
];
const testFlow = [
  text('title', 40, 0, 'How to test the app: identify, transact, sign, supervise, audit', 30),
  box('w1', 40, 70, 420, 90, 'A  Automatic\ndeploy.ps1 S3 runs Test-Workflow.ps1\nthe whole chain, on Lakeshore', '#d3f9d8', { fs: 17, stroke: '#2f9e44' }),
  box('w2', 500, 70, 420, 90, 'B  Status page  /status\nno sign-in, API, database\nand storage all say ok', '#e7f5ff', { fs: 17, stroke: '#1971c2' }),
  box('w3', 960, 70, 420, 90, 'C + D  By hand on a tablet\nRiverside Office Park\nsign-in details in demo.md', '#fff3bf', { fs: 17, stroke: '#f08c00' }),
  caption('c_steps', 40, 180, 1340, 30, 'C  The guard on the tablet. Each signature needs a drawing. The relief or cover guard types their own date of birth first.', 17),
];
steps.forEach(([id, label, see], i) => {
  const x = 40 + i * (SW + SG);
  testFlow.push(box(id, x, 220, SW, 105, label, '#ffec99', { fs: 16 }));
  testFlow.push(caption(`${id}c`, x, 332, SW, 44, see, 14, '#2f9e44'));
  if (i < steps.length - 1) testFlow.push(arrow(`as${i}`, x + SW, 272, [[0, 0], [SG, 0]]));
});
testFlow.push(caption('c_sup', 40, 400, 1340, 30, 'D  The supervisor reviews and audits the same day.', 17));
const UW = 300, UG = 60;
sup.forEach(([id, label, see], i) => {
  const x = 40 + i * (UW + UG);
  testFlow.push(box(id, x, 440, UW, 100, label, '#d0bfff', { fs: 17 }));
  testFlow.push(caption(`${id}c`, x, 546, UW, 44, see, 14, '#2f9e44'));
  if (i < sup.length - 1) testFlow.push(arrow(`au${i}`, x + UW, 490, [[0, 0], [UG, 0]]));
});
testFlow.push(
  box('rules', 1120, 440, 260, 150, 'Refused, nothing saved:\nwrong date of birth\nguard opens /supervisor\nend shift during break\nreject without a note', '#ffc9c9', { fs: 15, dash: true, stroke: '#e03131' }),
  caption('c_flow', 40, 620, 1340, 30, 'What one signed step does behind the scenes', 17),
  box('f_br', 40, 720, 200, 90, 'Tablet\nsignature pad', '#ffec99', { fs: 17 }),
  box('f_web', 290, 720, 200, 90, 'Web app\nchecks the session\nand role', '#a5d8ff', { fs: 15 }),
  box('f_api', 540, 720, 220, 90, 'API app\nshared key, rules,\nsecond-person DOB', '#d0bfff', { fs: 15 }),
  box('f_pg', 840, 670, 300, 80, 'PostgreSQL event: who, when,\nmeaning, SHA-256 of the PNG', '#b2f2bb', { fs: 15 }),
  box('f_st', 840, 770, 300, 75, 'Storage, private endpoint\nsignature PNG', '#c3fae8', { fs: 15 }),
  box('f_sb', 1190, 720, 190, 90, 'Daily record\nchecks the hash:\nVerified', '#d0bfff', { fs: 15 }),
  arrow('af1', 240, 765, [[0, 0], [50, 0]]),
  arrow('af2', 490, 765, [[0, 0], [50, 0]]),
  arrow('af3', 760, 765, [[0, 0], [40, 0], [40, -55], [80, -55]]),
  arrow('af4', 760, 765, [[0, 0], [40, 0], [40, 42], [80, 42]]),
  arrow('af5', 1140, 710, [[0, 0], [50, 30]], { dash: true }),
  arrow('af6', 1140, 807, [[0, 0], [50, -30]], { dash: true }),
);

// ---------- diagram 5: pilot path (pilot.md) ----------
const phases = [
  ['p1', 'Workshop demo', 'This repository', 'Synthetic data, one subscription\nID + date of birth sign-in\nlaptop deploys with deploy.ps1\n7-day backups, blob soft delete', '#e7f5ff', '#1971c2'],
  ['p2', 'Pilot: one site, 4 to 6 weeks', 'Real guards, one tablet per post', 'Entra ID sign-in, managed tablets\nsupervisor reviews the daily record\nmeasure: minutes per shift change,\ncorrections, overdue breaks', '#fff3bf', '#f08c00'],
  ['p3', 'Production', 'More sites, one at a time', 'CI/CD with protected environments\nprivate endpoints, WAF\n10-year immutable retention\nvalidation plan, training, policies', '#d3f9d8', '#2f9e44'],
];
const pilot = [text('title', 40, 0, 'From workshop demo to production', 32)];
phases.forEach(([id, name, sub, body, bg, stroke], i) => {
  const x = 40 + i * 470;
  pilot.push(box(id, x, 70, 420, 90, `${name}\n${sub}`, bg, { fs: 19, stroke }));
  pilot.push(box(`${id}b`, x, 175, 420, 130, body, '#ffffff', { fs: 16, stroke }));
  if (i < phases.length - 1) pilot.push(arrow(`ap${i}`, x + 420, 115, [[0, 0], [50, 0]], { sw: 3 }));
});
pilot.push(
  box('built', 40, 340, 650, 150, 'Built now (21 CFR Part 11 benchmark)\naudit trail that never overwrites (11.10 e)\nsteps enforced in order (11.10 f)\nsigner, time and meaning on every signature (11.50)\nlockouts reported to the supervisor (11.300 d)\nprint and CSV copies (11.10 b)', '#d3f9d8', { fs: 15, stroke: '#2f9e44' }),
  box('gaps', 730, 340, 650, 150, 'Gaps before production\na real secret instead of date of birth (11.200, 11.300 b)\nhash sealed with a key DBAs do not hold (11.70)\n10-year retention, immutable storage (1271.270 d)\nvalidation plan, training, written policies (11.10 a, i, j)\nFDA certification letter if ever regulated (11.100 c)', '#fff9db', { fs: 15, dash: true, stroke: '#f08c00' }),
);

// ---------- diagram 2: deployment stages ----------
const stages = [
  ['S0', 'Preflight', 'tools, sign-in,\nregion, quota, roles', '#e9ecef'],
  ['S1', 'Data tier', 'rg-data: PostgreSQL\n+ storage', '#b2f2bb'],
  ['S2', 'App tier', 'rg-app: apps, VNet,\nprivate endpoint, roles', '#a5d8ff'],
  ['S3', 'App code', 'zip deploy\n+ end-to-end checks', '#d0bfff'],
  ['S4', 'Cleanup', 'type team name\nnever in Autopilot', '#ffc9c9'],
];
const W = 190, GAP = 70, X0 = 40, Y0 = 220;
const FULL = 5 * W + 4 * GAP;
const deployment = [
  text('title', 40, 0, 'How deploy.ps1 runs', 32),
  caption('ask', 40, 52, FULL, 30, 'First it asks:  Deployment mode?', 20),
  box('m1', 40, 95, (FULL - 30) / 2, 80, 'Human in the loop (default)\nprints results, then asks  Continue? (y/n)', '#fff3bf', { fs: 18, stroke: '#f08c00' }),
  box('m2', 40 + (FULL + 30) / 2, 95, (FULL - 30) / 2, 80, 'Autopilot\nruns S0 to S3 without pausing', '#d3f9d8', { fs: 18, stroke: '#2f9e44' }),
];
stages.forEach(([id, name, sub, bg], i) => {
  const x = X0 + i * (W + GAP);
  deployment.push(box(id, x, Y0, W, 100, `${id}\n${name}`, bg, { fs: 22, dash: id === 'S4' }));
  deployment.push(caption(`${id}c`, x, Y0 + 110, W, 56, sub, 16, '#495057'));
  if (i < stages.length - 1) { deployment.push(arrow(`a${i}`, x + W, Y0 + 50, [[0, 0], [GAP, 0]])); deployment.push(caption(`y${i}`, x + W, Y0 + 18, GAP, 24, i === 3 ? 'y' : 'y / auto', 14, '#495057')); }
});
deployment.push(caption('stop', 40, 410, FULL, 40, 'In both modes a failed check stops the run.  Resume with:  .\\deploy.ps1 -Team team01 -StartAt S2', 18, '#e03131'));

// ---------- diagram 3: production RBAC ----------
const rbac = [
  text('title', 40, 0, 'Production: each team owns one resource group', 32),
  box('p1', 40, 80, 300, 90, 'Network engineers', '#ffec99'),
  box('p2', 400, 80, 300, 90, 'Database admins', '#ffec99'),
  box('p3', 760, 80, 300, 90, 'App developers\n+ pipeline identity', '#ffec99'),
  arrow('r1', 190, 170, [[0, 0], [0, 90]], { label: 'scoped role' }),
  arrow('r2', 550, 170, [[0, 0], [0, 90]], { label: 'scoped role' }),
  arrow('r3', 910, 170, [[0, 0], [0, 90]], { label: 'scoped role' }),
  box('g1', 40, 260, 300, 100, 'rg-network\nVNet, private endpoints, DNS', '#e5dbff', { fs: 18, dash: true }),
  box('g2', 400, 260, 300, 100, 'rg-data\nPostgreSQL, storage', '#b2f2bb', { fs: 18 }),
  box('g3', 760, 260, 300, 100, 'rg-app\nApp Service, monitoring', '#a5d8ff', { fs: 18 }),
  caption('note', 40, 390, 1020, 50, 'Workshop shortcut: no network group yet, and one runner is Owner on the whole subscription.', 18, '#e03131'),
];

const diagrams = { architecture, 'deployment-stages': deployment, 'production-rbac': rbac, 'test-flow': testFlow, 'pilot-path': pilot };

// ---------- render in headless Edge with the real Excalidraw library ----------
const browser = await chromium.launch({ channel: 'msedge', headless: true });
const page = await browser.newPage();
page.on('console', m => { if (m.type() === 'error') console.error('[page]', m.text()); });
await page.goto('https://esm.sh/');
await page.setContent(`<html><body><script type="module">
  window.EXCALIDRAW_ASSET_PATH = 'https://esm.sh/@excalidraw/excalidraw@0.18.0/dist/prod/';
  const ex = await import('https://esm.sh/@excalidraw/excalidraw@0.18.0?deps=react@19.0.0,react-dom@19.0.0');
  window.ex = ex; window.ready = true;
</script></body></html>`);
await page.waitForFunction(() => window.ready === true, null, { timeout: 120000 });

for (const [name, skel] of Object.entries(diagrams)) {
  if (only && only !== name) continue;
  const svg = await page.evaluate(async (skel) => {
    const { convertToExcalidrawElements, exportToSvg } = window.ex;
    const elements = convertToExcalidrawElements(skel, { regenerateIds: false });
    const el = await exportToSvg({
      elements,
      appState: { exportBackground: true, viewBackgroundColor: '#ffffff', exportEmbedScene: true, exportWithDarkMode: false },
      files: null,
      exportPadding: 24,
    });
    return el.outerHTML;
  }, skel);
  const file = path.join(outDir, `${name}.excalidraw.svg`);
  fs.writeFileSync(file, svg);
  console.log(`${file} ${Math.round(svg.length / 1024)} KB`);
}
await browser.close();



