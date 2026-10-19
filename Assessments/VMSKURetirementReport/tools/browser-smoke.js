#!/usr/bin/env node
// Browser smoke test for the generated HTML report (development only, not shipped in the package).
// The report has no scripts: the collapsible VM details use a hidden checkbox + label and CSS :has(), and the
// whole row toggles through a label overlay. Pester can only check that markup and CSS strings exist, so this
// opens the report in real engines and checks the behaviour.
//
//   cd tools; npm i --no-save playwright-core
//   npx playwright-core install firefox webkit        # optional; msedge/chrome use the installed browser
//   node browser-smoke.js [report-folder] [engine ...]  # engines: msedge, chrome, firefox, webkit (default: msedge)
//
// The report folder defaults to ../examples/sample-report. Exit code 1 when any check fails.
'use strict';
const path = require('path');
const fs = require('fs');
let pw;
try { pw = require('playwright-core'); } catch { console.error('playwright-core is not installed (npm i --no-save playwright-core).'); process.exit(2); }

const dir = path.resolve(process.argv[2] || path.join(__dirname, '..', 'examples', 'sample-report'));
const wanted = process.argv.slice(3).length ? process.argv.slice(3) : ['msedge'];
const pageFile = fs.readdirSync(dir).find(f => /^contoso-prod-.*\.html$/.test(f)) || fs.readdirSync(dir).find(f => f.endsWith('.html') && f !== 'index.html');
if (!pageFile) { console.error(`No subscription report page (*.html other than index.html) found in ${dir}.`); process.exit(2); }
const url = 'file:///' + path.join(dir, pageFile).replace(/\\/g, '/');
const launchers = {
  msedge: () => pw.chromium.launch({ channel: 'msedge', headless: true }),
  chrome: () => pw.chromium.launch({ channel: 'chrome', headless: true }),
  firefox: () => pw.firefox.launch({ headless: true }),
  webkit: () => pw.webkit.launch({ headless: true }),
};

async function checks(browser) {
  const out = [];
  const ok = (name, pass) => out.push([name, !!pass]);
  const ctx = await browser.newContext({ viewport: { width: 1500, height: 1000 } });
  const p = await ctx.newPage();
  await p.goto(url);
  const display = i => p.locator('tr.vm-detail-row').nth(i).evaluate(e => getComputedStyle(e).display);
  ok('detail rows are collapsed by default', await p.locator('tr.vm-detail-row').evaluateAll(els => els.length > 0 && els.every(e => getComputedStyle(e).display === 'none')));

  const geo = await p.evaluate(() => {
    const row = document.querySelectorAll('tr.vm-summary-row')[0];
    const a = getComputedStyle(row.querySelector('.vm-toggle-label'), '::after');
    const r = row.getBoundingClientRect();
    return { dw: Math.abs(parseFloat(a.width) - r.width), dh: Math.abs(parseFloat(a.height) - r.height) };
  });
  ok('row overlay is exactly the size of its row', geo.dw < 3 && geo.dh < 3);

  await p.locator('.toc a', { hasText: 'Quota' }).first().click();
  ok('page links outside the table still work', (await p.evaluate(() => location.hash)) === '#quota');
  await p.evaluate(() => scrollTo(0, 0));

  const row = p.locator('tr.vm-summary-row').nth(1);
  await row.scrollIntoViewIfNeeded();
  const box = await row.locator('td').nth(2).boundingBox();
  await p.mouse.click(box.x + box.width - 6, box.y + box.height - 6);
  ok('clicking a plain cell opens the details', (await display(1)) === 'table-row');
  await p.mouse.click(box.x + box.width - 6, box.y + box.height - 6);
  ok('clicking it again closes them', (await display(1)) === 'none');
  await row.locator('.vm-toggle-label').click();
  ok('the Details pill opens them', (await display(1)) === 'table-row');
  await row.locator('.vm-toggle-label').click();
  await p.locator('tr.vm-summary-row').nth(0).locator('.vm-toggle').focus();
  await p.keyboard.press('Space');
  ok('Space on the focused checkbox toggles', (await display(0)) === 'table-row');
  await p.keyboard.press('Space');

  ok('the VM name stays selectable (not under the overlay)', await row.locator('td').first().locator('.strong').evaluate(el => { const r = el.getBoundingClientRect(); return document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2) === el; }));

  await p.locator('label.vm-toggle-all-label').click();
  ok('Expand all opens every detail row', await p.locator('tr.vm-detail-row').evaluateAll(els => els.every(e => getComputedStyle(e).display === 'table-row')));
  await p.locator('label.vm-toggle-all-label').click();

  await row.locator('.vm-toggle-label').click();
  await p.locator('tr.vm-detail-row').nth(1).locator('.vd-more summary').click();
  ok('"Show all attributes" opens inside the row', await p.locator('tr.vm-detail-row').nth(1).locator('.vd-more').evaluate(e => e.open));

  await p.emulateMedia({ media: 'print' });
  ok('print shows every detail row and hides the controls', await p.locator('tr.vm-detail-row').evaluateAll(els => els.every(e => getComputedStyle(e).display === 'table-row')) &&
    (await p.locator('.vm-toggle-label').first().evaluate(e => getComputedStyle(e).display)) === 'none');
  ok('print shows the full comparison behind "Show all attributes"', await p.locator('.vd-more').first().evaluate(e => { const t = e.querySelector('table'); return !!t && t.getBoundingClientRect().height > 0; }));
  await ctx.close();

  for (const [label, width] of [['1100px', 1100], ['phone 390px', 390]]) {
    const c = await browser.newContext({ viewport: { width, height: 800 } });
    const q = await c.newPage(); await q.goto(url);
    await q.locator('tr.vm-summary-row').nth(1).locator('.vm-toggle-label').click();
    const w = await q.locator('tr.vm-detail-row').nth(1).locator('.vm-detail').boundingBox();
    ok(`${label}: details fit the viewport without page overflow`, w.width <= width && !(await q.evaluate(() => document.documentElement.scrollWidth > innerWidth)));
    await c.close();
  }
  return out;
}

(async () => {
  let failed = 0;
  for (const name of wanted) {
    if (!launchers[name]) { console.error(`Unknown engine ${name}`); failed++; continue; }
    let results;
    try { const b = await launchers[name](); results = await checks(b); await b.close(); }
    catch (e) { console.log(`${name}: ERROR ${String(e).split('\n')[0]}`); failed++; continue; }
    for (const [check, pass] of results) { console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}: ${check}`); if (!pass) failed++; }
  }
  process.exit(failed ? 1 : 0);
})();
