import { chromium } from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Renders the README diagrams with the Excalidraw library in headless Microsoft Edge.
// Usage: npm install, then node render.mjs [architecture|deployment-stages|production-rbac]
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

  zone('zapp', 260, 100, 620, 320, '#e7f5ff', '#1971c2'),
  text('zappt', 280, 112, 'rg-<team>-app', 20, '#1971c2'),
  box('web', 290, 160, 240, 100, 'Web app\nPython, public', '#a5d8ff'),
  box('api', 610, 160, 240, 100, 'API app\nFastAPI', '#d0bfff'),
  box('appi', 290, 300, 240, 90, 'Application Insights\n+ Log Analytics', '#eebefa', { fs: 18 }),
  box('mi', 610, 300, 240, 90, 'Managed identity\n= PostgreSQL admin', '#fff3bf', { fs: 18 }),

  zone('znet', 260, 480, 620, 250, '#f3f0ff', '#6741d9'),
  text('znett', 280, 492, 'rg-<team>-network', 20, '#6741d9'),
  box('snapp', 290, 540, 260, 80, 'snet-app-integration', '#e5dbff', { fs: 18 }),
  box('snpe', 590, 540, 260, 80, 'snet-private-endpoints', '#e5dbff', { fs: 18 }),
  box('dns', 290, 640, 560, 64, 'Private DNS  privatelink.postgres.database.azure.com', '#fff3bf', { fs: 16 }),

  zone('zdata', 930, 480, 320, 250, '#ebfbee', '#2f9e44'),
  text('zdatat', 950, 492, 'rg-<team>-data', 20, '#2f9e44'),
  box('pe', 960, 540, 260, 70, 'Private endpoint', '#b2f2bb', { fs: 18 }),
  box('pg', 960, 630, 260, 80, 'PostgreSQL\npublic access off', '#b2f2bb', { fs: 18 }),

  arrow('a_bw', 210, 210, [[0, 0], [80, 0]]),
  caption('l_bw', 210, 178, 80, 24, 'HTTPS', 16),
  arrow('a_wa', 530, 210, [[0, 0], [80, 0]]),
  caption('l_wa', 530, 178, 80, 24, 'HTTPS', 16),
  arrow('a_ap', 850, 210, [[0, 0], [240, 0], [240, 330]]),
  text('l_ap', 1102, 300, 'SQL 5432\nEntra token', 16),
  arrow('a_blk', 125, 160, [[0, 0], [0, -90], [605, -90], [605, 0]], { color: '#e03131', dash: true, end: 'bar' }),
  text('l_blk', 450, 44, 'direct call to API: 403', 16, '#e03131'),
  arrow('a_vnet', 490, 420, [[0, 0], [0, 120]], { dash: true, color: '#6741d9' }),
  text('l_vnet', 502, 440, 'outbound via VNet integration', 16, '#6741d9'),
  arrow('a_peip', 960, 575, [[0, 0], [-110, 0]], { dash: true, color: '#2f9e44', end: null }),
  caption('legend', 40, 760, 1210, 40, 'Only the web app is public. The API accepts calls only from the web app\'s subnet. The database has no public access and no password.', 18, '#495057'),
];

// ---------- diagram 2: deployment stages ----------
const stages = [
  ['S0', 'Preflight', 'tools, sign-in,\nregion, quota', '#e9ecef'],
  ['S1', 'Network', 'rg-network\nBicep', '#e5dbff'],
  ['S2', 'Database', 'rg-data\nBicep', '#b2f2bb'],
  ['S3', 'App tier', 'rg-app\nBicep', '#a5d8ff'],
  ['S4', 'App code', 'rg-app\nzip deploy', '#a5d8ff'],
  ['S5', 'Cleanup', 'deletes the\n3 groups', '#ffc9c9'],
];
const W = 170, GAP = 60, X0 = 40, Y0 = 170;
const deployment = [
  text('title', 40, 0, 'How deploy.ps1 runs', 32),
  box('gate', 40, 60, 6 * W + 5 * GAP, 60, 'After every stage the script prints what it deployed and the check results, then asks:  Continue? (y/n)', '#fff3bf', { fs: 18, dash: true, stroke: '#f08c00' }),
];
stages.forEach(([id, name, sub, bg], i) => {
  const x = X0 + i * (W + GAP);
  deployment.push(box(id, x, Y0, W, 100, `${id}\n${name}`, bg, { fs: 22 }));
  deployment.push(caption(`${id}c`, x, Y0 + 110, W, 56, sub, 16, '#495057'));
  if (i < stages.length - 1) { deployment.push(arrow(`a${i}`, x + W, Y0 + 50, [[0, 0], [GAP, 0]])); deployment.push(caption(`y${i}`, x + W, Y0 + 18, GAP, 24, 'y', 16, '#495057')); }
});
deployment.push(caption('stop', 40, 360, 6 * W + 5 * GAP, 40, 'Answering n, or any failed check, stops the run.  Resume with:  .\\deploy.ps1 -Team team01 -StartAt S3', 18, '#e03131'));

// ---------- diagram 3: production RBAC ----------
const rbac = [
  text('title', 40, 0, 'Production: each team owns one resource group', 32),
  box('p1', 40, 80, 300, 90, 'Network engineers', '#ffec99'),
  box('p2', 400, 80, 300, 90, 'Database admins', '#ffec99'),
  box('p3', 760, 80, 300, 90, 'App developers\n+ pipeline identity', '#ffec99'),
  arrow('r1', 190, 170, [[0, 0], [0, 90]], { label: 'scoped role' }),
  arrow('r2', 550, 170, [[0, 0], [0, 90]], { label: 'scoped role' }),
  arrow('r3', 910, 170, [[0, 0], [0, 90]], { label: 'scoped role' }),
  box('g1', 40, 260, 300, 100, 'rg-network\nVNet, subnets, DNS', '#e5dbff', { fs: 18 }),
  box('g2', 400, 260, 300, 100, 'rg-data\nPostgreSQL, endpoint', '#b2f2bb', { fs: 18 }),
  box('g3', 760, 260, 300, 100, 'rg-app\nApp Service, monitoring', '#a5d8ff', { fs: 18 }),
  caption('note', 40, 390, 1020, 40, 'Workshop shortcut: one runner has Contributor on the whole subscription.', 18, '#e03131'),
];

const diagrams = { architecture, 'deployment-stages': deployment, 'production-rbac': rbac };

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

