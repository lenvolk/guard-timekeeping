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

  zone('zapp', 260, 90, 580, 360, '#e7f5ff', '#1971c2'),
  text('zappt', 280, 102, 'rg-<team>-app', 20, '#1971c2'),
  box('web', 290, 160, 240, 100, 'Web app\nUI + signature pad', '#a5d8ff'),
  box('api', 570, 160, 240, 100, 'API app\nFastAPI', '#d0bfff'),
  box('appi', 290, 320, 240, 90, 'Application Insights\n+ Log Analytics', '#eebefa', { fs: 18 }),
  box('mi', 570, 320, 240, 90, 'API managed identity\n(no passwords, no keys)', '#fff3bf', { fs: 18 }),

  zone('zdata', 1040, 90, 340, 360, '#ebfbee', '#2f9e44'),
  text('zdatat', 1060, 102, 'rg-<team>-data', 20, '#2f9e44'),
  box('pg', 1070, 160, 280, 100, 'PostgreSQL B1ms\nEntra sign-in only', '#b2f2bb', { fs: 18 }),
  box('st', 1070, 320, 280, 90, 'Storage account\nsignatures/*.png', '#c3fae8', { fs: 18 }),

  arrow('a_bw', 210, 210, [[0, 0], [80, 0]]),
  caption('l_bw', 210, 178, 80, 24, 'HTTPS', 16),
  arrow('a_wa', 530, 210, [[0, 0], [40, 0]]),
  arrow('a_ami', 690, 260, [[0, 0], [0, 60]], { dash: true, end: null, color: '#f08c00' }),
  arrow('a_pg', 810, 210, [[0, 0], [260, 0]]),
  caption('l_pg', 830, 166, 220, 40, 'SQL + token\nPostgreSQL admin', 14),
  arrow('a_st', 810, 365, [[0, 0], [260, 0]]),
  caption('l_st', 830, 321, 220, 40, 'writes PNGs\nBlob Data Contributor', 14),

  box('runner', 1070, 530, 280, 80, 'Runner in Azure portal', '#ffec99', { fs: 18 }),
  arrow('a_rs', 1210, 530, [[0, 0], [0, -120]]),
  caption('l_rs', 1060, 466, 140, 30, 'Blob Data Reader', 14),

  box('prod', 40, 530, 800, 80, 'Production adds: VNet, private endpoints for the database, storage and API, private DNS, WAF', '#fff9db', { fs: 16, dash: true, stroke: '#f08c00' }),
  caption('legend', 40, 640, 1340, 40, 'All endpoints are public for the workshop. Every service checks an Entra ID identity instead of a password or key.', 18, '#495057'),
];

// ---------- diagram 2: deployment stages ----------
const stages = [
  ['S0', 'Preflight', 'tools, sign-in,\nregion, quota, roles', '#e9ecef'],
  ['S1', 'Data tier', 'rg-data: PostgreSQL\n+ storage', '#b2f2bb'],
  ['S2', 'App tier', 'rg-app: apps,\nidentity, roles', '#a5d8ff'],
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

