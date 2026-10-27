import { chromium } from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Renders the README diagrams with the Excalidraw library in headless Microsoft Edge.
// Usage: npm install, then node render.mjs [architecture|deployment-stages|production-rbac|test-flow]
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

  box('browser', 40, 160, 170, 100, 'Browser\n(internet)', '#ffec99'),

  zone('zapp', 260, 90, 590, 560, '#e7f5ff', '#1971c2'),
  text('zappt', 280, 102, 'rg-<team>-app', 20, '#1971c2'),
  box('web', 290, 160, 240, 100, 'Web app\nUI + signature pad', '#a5d8ff'),
  box('api', 570, 160, 250, 100, 'API app\nFastAPI\nmanaged identity', '#d0bfff', { fs: 18 }),
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
  arrow('a_snet', 695, 260, [[0, 0], [0, 90]], { color: '#7048e8' }),
  arrow('a_pe', 695, 440, [[0, 0], [0, 70]], { color: '#7048e8' }),
  arrow('a_pg', 820, 210, [[0, 0], [250, 0]]),
  caption('l_pg', 850, 140, 180, 60, 'SQL + Entra token\nPostgreSQL admin\npublic endpoint', 14),
  arrow('a_st', 815, 555, [[0, 0], [255, 0]], { color: '#7048e8' }),
  caption('l_st', 840, 490, 210, 60, 'writes + reads PNGs\nBlob Data Contributor\nprivate IP only', 14, '#7048e8'),

  box('runner', 1070, 730, 280, 80, 'Workshop runner (you)\nin the Azure portal', '#ffec99', { fs: 18 }),
  arrow('a_rs', 1210, 730, [[0, 0], [0, -130]], { dash: true, color: '#e03131' }),
  caption('l_rs', 1215, 650, 190, 60, 'Blob Data Reader\nblocked if a policy turns\npublic access off', 14, '#e03131'),

  box('prod', 40, 730, 980, 70, 'Production adds: private endpoints for PostgreSQL and the API, a WAF, and a deployment runner inside the VNet', '#fff9db', { fs: 16, dash: true, stroke: '#f08c00' }),
  caption('legend', 40, 830, 1340, 50, 'The web app, API and PostgreSQL use public endpoints. PostgreSQL accepts Azure services only.\nBlob Storage is reached only through the private endpoint. Every service checks an Entra ID identity, never a password or key.', 16, '#495057'),
];

// ---------- diagram 4: how to test (demo.md) ----------
const SW = 230, SG = 50;
const steps = [
  ['s1', '1  Start shift\nJordan Avila\nwitness + signature', 'Jordan: Off Shift\n-> Available'],
  ['s2', '2  Take post\nLobby Desk\n(vacant)', 'Jordan: Available\n-> On Post'],
  ['s3', '3  Hand over\nto Marcus Ferrin\n(Available), he signs', 'Marcus: On Post\nJordan: Available'],
  ['s4', '4  End shift\nJordan Avila\nsigns', 'Jordan: Available\n-> Off Shift'],
  ['s5', '5  Check\nsupervisor board', 'Lobby Desk: Marcus,\nsignature thumbnails'],
];
const testFlow = [
  text('title', 40, 0, 'How to test the app', 32),
  box('w1', 40, 70, 420, 100, 'A  Automatic\ndeploy.ps1 S3 runs\nscripts\\Test-Workflow.ps1', '#d3f9d8', { fs: 18, stroke: '#2f9e44' }),
  box('w2', 500, 70, 420, 100, 'B  Status page  /status\nAPI, database and storage\nall say ok', '#e7f5ff', { fs: 18, stroke: '#1971c2' }),
  box('w3', 960, 70, 430, 100, 'C  By hand in a browser\nthe five steps below,\nRiverside Office Park', '#fff3bf', { fs: 18, stroke: '#f08c00' }),
  caption('c_steps', 40, 200, 1350, 30, 'C: first walkthrough on a new deployment. You act as each guard by clicking their name. There is no sign-in.', 18),
];
steps.forEach(([id, label, see], i) => {
  const x = 40 + i * (SW + SG);
  testFlow.push(box(id, x, 245, SW, 110, label, i === 4 ? '#d0bfff' : '#ffec99', { fs: 18 }));
  testFlow.push(caption(`${id}c`, x, 365, SW, 50, see, 15, '#2f9e44'));
  if (i < steps.length - 1) testFlow.push(arrow(`as${i}`, x + SW, 300, [[0, 0], [SG, 0]]));
});
testFlow.push(
  caption('c_flow', 40, 450, 1350, 30, 'What one signed step does behind the scenes', 18),
  box('f_br', 40, 520, 210, 90, 'Your browser\nsignature pad', '#ffec99', { fs: 18 }),
  box('f_web', 300, 520, 210, 90, 'Web app', '#a5d8ff', { fs: 18 }),
  box('f_api', 560, 520, 210, 90, 'API app\nchecks the rules', '#d0bfff', { fs: 18 }),
  box('f_pg', 860, 480, 300, 75, 'PostgreSQL\nevent row: who, when, what', '#b2f2bb', { fs: 16 }),
  box('f_st', 860, 585, 300, 75, 'Storage, private endpoint\nsignature PNG', '#c3fae8', { fs: 16 }),
  box('f_sb', 1210, 520, 180, 90, 'Supervisor board\nshows both', '#d0bfff', { fs: 16 }),
  arrow('af1', 250, 565, [[0, 0], [50, 0]]),
  arrow('af2', 510, 565, [[0, 0], [50, 0]]),
  arrow('af3', 770, 565, [[0, 0], [45, 0], [45, -47], [90, -47]]),
  arrow('af4', 770, 565, [[0, 0], [45, 0], [45, 57], [90, 57]]),
  arrow('af5', 1160, 517, [[0, 0], [50, 30]], { dash: true }),
  arrow('af6', 1160, 622, [[0, 0], [50, -30]], { dash: true }),
  caption('c_rule', 40, 690, 1350, 40, 'A step the rules do not allow, such as ending a shift while still on a post, shows a message and saves nothing.', 16, '#495057'),
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

const diagrams = { architecture, 'deployment-stages': deployment, 'production-rbac': rbac, 'test-flow': testFlow };

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

