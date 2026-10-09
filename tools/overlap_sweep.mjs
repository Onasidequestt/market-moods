// Overlap sweep (Clark 10-08: "when the site is resized in a laptop browser it smashes together all the elements").
// One real Chromium tab per page, loaded once and then RESIZED through every width 320→1920 (40px steps) at 800 tall,
// plus short and phone windows. After each resize it waits for the page to settle, then boxes every visible text run,
// image and control, and every blob's core. Fails on: two boxes of different items that intersect (neither inside
// the other), any box past the window edge, a blob's core over any text/control outside the stage labels, or two
// economy blobs (each keeps its body to itself) on top of each other.
// usage: node tools/overlap_sweep.mjs <base url> <browser binary> [page ...]   (exit 1 on any overlap, 2 if it cannot run)
//        OVERLAP_SHOTS=<dir> also saves the measured frame of every page×size as a PNG
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [, , BASE, BIN, ...pagesArg] = process.argv;
if (!BASE || !BIN) { console.log("✘ overlap: usage: overlap_sweep.mjs <base url> <browser> [page ...]"); process.exit(2); }
const PAGES = pagesArg.length ? pagesArg : ["index.html", "economy.html"];
const SIZES = [];
for (let w = 1920; w >= 320; w -= 40) SIZES.push([w, 800]);   // shrinking, as a hand drags the window edge in
SIZES.push([1440, 800], [1280, 720], [1366, 640], [1024, 600], [390, 844], [390, 664], [320, 568], [844, 390]);

// runs IN the page: same rules as the header comment
const PROBE = `(() => {
  const vw = innerWidth, vh = innerHeight, items = [];
  const shown = el => { for (let e = el; e && e.nodeType === 1; e = e.parentElement) { const cs = getComputedStyle(e);
    if (cs.display === "none" || cs.visibility === "hidden" || +cs.opacity < 0.05 || e.hidden || e.hasAttribute("inert")) return false; } return true; };
  const clip = (r, el, self) => { let [x0, y0, x1, y1] = [r.left, r.top, r.right, r.bottom];   // self: a text run is cut by its own element's overflow too (an ellipsis)
    for (let e = self ? el : el.parentElement; e && e !== document.body; e = e.parentElement) { const cs = getComputedStyle(e);
      if (cs.overflowX !== "visible" || cs.overflowY !== "visible") { const c = e.getBoundingClientRect();
        x0 = Math.max(x0, c.left); y0 = Math.max(y0, c.top); x1 = Math.min(x1, c.right); y1 = Math.min(y1, c.bottom); } }
    return x1 - x0 > 0.5 && y1 - y0 > 0.5 ? [x0, y0, x1, y1] : null; };
  const add = (el, r, what, self) => { const b = clip(r, el, self); if (b) items.push({ el, b, what }); };
  const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = tw.nextNode());) { if (!n.nodeValue.trim()) continue; const el = n.parentElement;
    if (/SCRIPT|STYLE/.test(el.tagName) || !shown(el)) continue;
    const rg = document.createRange(); rg.selectNodeContents(n);
    for (const r of rg.getClientRects()) if (r.width > 0.5 && r.height > 0.5) add(el, r, n.nodeValue.trim().slice(0, 22), true); }
  document.querySelectorAll("img, svg, button, input, select, .btn").forEach(el => {
    if (el.parentElement && el.parentElement.closest("svg")) return;
    if (shown(el)) add(el, el.getBoundingClientRect(), "<" + el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") + ">"); });
  const nm = el => el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") + (typeof el.className === "string" && el.className ? "." + el.className.split(" ")[0] : "");
  const bad = [];
  for (const a of items) { const b = a.b; if (b[0] < -0.5 || b[1] < -0.5 || b[2] > vw + 0.5 || b[3] > vh + 0.5) bad.push("past the edge: " + nm(a.el) + " '" + a.what + "'"); }
  for (let i = 0; i < items.length; i++) for (let j = i + 1; j < items.length; j++) { const A = items[i], B = items[j];
    if (A.el === B.el || A.el.contains(B.el) || B.el.contains(A.el)) continue;
    const ox = Math.min(A.b[2], B.b[2]) - Math.max(A.b[0], B.b[0]), oy = Math.min(A.b[3], B.b[3]) - Math.max(A.b[1], B.b[1]);
    if (ox > 1 && oy > 1) bad.push(nm(A.el) + " '" + A.what + "' × " + nm(B.el) + " '" + B.what + "' (" + Math.round(ox) + "x" + Math.round(oy) + ")"); }
  // a blob's core (a circle) over text or a control that is not a stage label: wax over the header, caption or footer
  const hook = window.__mm || window.__em, blobs = hook && hook.blobs ? hook.blobs() : [];
  for (const c of blobs) for (const a of items) { if (a.el.closest(".tags")) continue; const b = a.b;
    const dx = Math.max(b[0] - c.x, 0, c.x - b[2]), dy = Math.max(b[1] - c.y, 0, c.y - b[3]);
    if (Math.hypot(dx, dy) < c.r - 1) bad.push("blob at " + Math.round(c.x) + "," + Math.round(c.y) + " r" + Math.round(c.r) + " × " + nm(a.el) + " '" + a.what + "'"); }
  // two blobs that each keep their body to themselves (economy groups) must not sit on each other
  for (let i = 0; i < blobs.length; i++) for (let j = i + 1; j < blobs.length; j++) { const a = blobs[i], b = blobs[j];
    if (a.own && b.own && Math.hypot(a.x - b.x, a.y - b.y) < a.r + b.r - 1) bad.push("blob on blob at " + Math.round(a.x) + "," + Math.round(a.y) + " and " + Math.round(b.x) + "," + Math.round(b.y)); }
  return JSON.stringify({ n: items.length, blobs: blobs.length, bad });
})()`;

const prof = mkdtempSync(join(tmpdir(), "mm-ovl-")), port = 9400 + Math.floor(Math.random() * 500);   // a fresh port: a reused one serves a stale page
const br = spawn(BIN, ["--headless", `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`, "--use-angle=swiftshader",
  "--enable-unsafe-swiftshader", "--hide-scrollbars", "--window-size=1920,800", "about:blank"], { stdio: "ignore" });
const done = code => { try { br.kill("SIGKILL"); } catch {} try { rmSync(prof, { recursive: true, force: true }); } catch {} process.exit(code); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
let target;
for (let k = 0; k < 50 && !target; k++) { await sleep(200);
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(t => t.type === "page"); } catch {} }
if (!target) { console.log("✘ overlap: the browser never opened a debug port"); done(2); }
const ws = new WebSocket(target.webSocketDebuggerUrl); let id = 0; const pend = new Map();
ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pend.has(m.id)) { const p = pend.get(m.id); pend.delete(m.id); m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result); } };
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pend.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
const evalJS = async expr => (await send("Runtime.evaluate", { expression: expr, returnByValue: true })).result.value;
const size = (w, h) => send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: w < 700 });

let total = 0, runs = 0;
for (const page of PAGES) {
  await size(...SIZES[0]); await send("Page.navigate", { url: BASE.replace(/\/?$/, "/") + page });
  for (let k = 0; k < 60; k++) { await sleep(250); if (await evalJS("!!(window.__mm || window.__em) && document.readyState === 'complete' && !!document.querySelector('.tags span[style*=visible]')")) break; }
  await sleep(1500);   // data in, first frames drawn
  for (const [w, h] of SIZES) {
    await size(w, h); await sleep(700);   // the lamp re-measures on its next frames; labels glide .25s
    let r = JSON.parse(await evalJS(PROBE)); runs++;
    // ponytail: a label gliding past a neighbour (.25s) is motion, not layout. An overlap counts only if it is still there
    // 450ms later (same pair, any size). Ceiling: a collision that flickers on and off faster than that is not caught.
    if (r.bad.length) { await sleep(450); const again = new Set(JSON.parse(await evalJS(PROBE)).bad.map(k => k.replace(/ ?\(?[\d,x ]+\)?$|at [\d,]+( and [\d,]+)?|r\d+/g, "")));
      r.bad = r.bad.filter(k => again.has(k.replace(/ ?\(?[\d,x ]+\)?$|at [\d,]+( and [\d,]+)?|r\d+/g, ""))); }
    if (process.env.OVERLAP_SHOTS) writeFileSync(join(process.env.OVERLAP_SHOTS, `${page.replace(".html", "")}_${w}x${h}.png`),
      Buffer.from((await send("Page.captureScreenshot", { format: "png" })).data, "base64"));   // the frame the probe measured, for eyes
    if (!r.n || !r.blobs) { console.log(`✘ overlap ${page} ${w}x${h}: probe saw ${r.n} boxes, ${r.blobs} blobs (cannot verify)`); total++; continue; }
    for (const b of r.bad) { console.log(`✘ overlap ${page} ${w}x${h}: ${b}`); total++; }
  }
}
console.log(total ? `✘ overlap: ${total} finding(s) over ${runs} page×size runs` : `✓ overlap: no element box overlaps over ${runs} page×size runs (${SIZES.length} sizes × ${PAGES.length} pages, resized live)`);
ws.close(); done(total ? 1 : 0);
