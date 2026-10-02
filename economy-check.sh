#!/bin/sh
# economy.html in REAL Chromium (software WebGL), phone and desktop width:
#  1. the lamp: one blob per group (5 x 5 wax drops drawn), 5 cards whose % equals a recount made HERE
#     from data/economy.json with mood.js, a status pill that says delayed/closed with a time
#  2. inside each group (#g=<key>): one drawn blob and one list row per member, each row's move text
#     recounted from the data file, every weekly/monthly row carrying its own date and never "delayed"
#  3. the honest empty states: no data file = notice, no cards, no wax; a not-live series (cobalt) is
#     named on its group's page with its reason
# usage: sh economy-check.sh      (serves this folder on 127.0.0.1:8768 while it runs)
cd "$(dirname "$0")" || exit 2
B="$HOME/.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.42/chrome-headless-shell-mac-arm64/chrome-headless-shell"
[ -x "$B" ] || { echo "✘ economy-check: chrome-headless-shell not found"; exit 2; }
[ -f data/economy.json ] || { echo "✘ economy-check: data/economy.json missing (run: python3 fetch.py --economy)"; exit 2; }
T=$(mktemp -d); mkdir -p "$T/nodata" "$T/same/data"; cp economy.html mood.js "$T/nodata/"
# "same": every economy group makes the SAME big move (eight copies of metals, every member +4%), so on a phone the
# eight front blobs sit side by side a 49px lane apart (where summed fields bridge neighbours: r3 Energy/Metals fused)
# and every economy-page blob is as big as it gets, edge lanes included (r3: Central banks clipped at the right edge)
cp index.html economy.html mood.js "$T/same/"; cp data/market.json data/companies*.json "$T/same/data/"
node -e 'const e=require("./data/economy.json"), g=e.groups.find(x=>x.key==="metals"); e.groups=[...Array(8)].map((_,i)=>({...g,key:"same"+i,name:"Same "+i,short:"Same "+i,members:g.members.map(m=>({...m,last:m.prev*1.04}))})); process.stdout.write(JSON.stringify(e))' > "$T/same/data/economy.json"
python3 -m http.server 8768 --bind 127.0.0.1 >/dev/null 2>&1 & SRV=$!
ln -s "$T/nodata" ./.econ-nodata-check 2>/dev/null; ln -s "$T/same" ./.econ-same-check 2>/dev/null
trap 'kill $SRV 2>/dev/null; rm -rf "$T"; rm -f ./.econ-nodata-check ./.econ-same-check' EXIT
sleep 1
shoot() { # $1 size  $2 url  $3 out
  P=$(mktemp -d)
  "$B" --headless --user-data-dir="$P" --use-angle=swiftshader --enable-unsafe-swiftshader --hide-scrollbars \
    --window-size="$1" --virtual-time-budget=6000 --screenshot="$3.png" "$2" >/dev/null 2>&1
  "$B" --headless --user-data-dir="$P" --use-angle=swiftshader --enable-unsafe-swiftshader \
    --window-size="$1" --virtual-time-budget=6000 --dump-dom "$2" 2>/dev/null > "$3.html"
  rm -rf "$P"
}
KEYS=$(node -e 'console.log(require("./data/economy.json").groups.map(g=>g.key).join(" "))')
for SIZE in 390,844 1440,900; do
  shoot $SIZE "http://127.0.0.1:8768/economy.html?probe" "$T/lamp_$SIZE"
  shoot $SIZE "http://127.0.0.1:8768/.econ-nodata-check/economy.html" "$T/no_$SIZE"
  for K in $KEYS; do shoot $SIZE "http://127.0.0.1:8768/economy.html#g=$K" "$T/g_${K}_$SIZE"; done
  shoot $SIZE "http://127.0.0.1:8768/index.html" "$T/front_$SIZE"   # mm19: the groups ride on the front page too
  shoot $SIZE "http://127.0.0.1:8768/.econ-same-check/index.html?probe" "$T/same_$SIZE"
  shoot $SIZE "http://127.0.0.1:8768/.econ-same-check/economy.html?probe" "$T/samelamp_$SIZE"
done
shoot 390,568 "http://127.0.0.1:8768/.econ-same-check/economy.html?probe" "$T/short"   # r4: a short phone, where two rows would not fit
mkdir -p shots/economy; for K in $KEYS; do cp "$T/g_${K}_390,844.png" "shots/economy/${K}_phone.png"; done
cp "$T/lamp_390,844.png" shots/economy/lamp_phone.png; cp "$T/lamp_1440,900.png" shots/economy/lamp_desktop.png
node - "$T" "$KEYS" <<'EOJ'
const fs = require("fs"), M = require("./mood.js"), assert = require("assert");
const [T, keys] = [process.argv[2], process.argv[3].split(" ")];
const e = JSON.parse(fs.readFileSync("data/economy.json", "utf8"));
let n = 0, bad = 0;
const ok = (c, m) => { n++; if (!c) { bad++; console.log("  ✘ " + m); } };
const dom = f => fs.readFileSync(`${T}/${f}.html`, "utf8");
const attr = (h, re) => { const m = re.exec(h); return m ? m[1] : null; };
const text = h => h.replace(/<[^>]+>/g, "\u0001").split("\u0001").map(x => x.trim()).filter(Boolean);
const dec = s => s.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
const groupPct = g => M.econGroupPct(g.members.map(m => ({ m, move: M.econMove(m.kind, m.prev, m.last) })));
const fmt = p => (p >= 0 ? "+" : "−") + Math.abs(p).toFixed(2) + "%";
for (const SIZE of ["390,844", "1440,900"]) {
  const L = dom("lamp_" + SIZE), tag = SIZE.startsWith("390") ? "phone" : "desktop";
  ok(attr(L, /data-drops="(\d+)"/) == e.groups.length * 5, `${tag}: ${e.groups.length} blobs x 5 drops of wax drawn (${attr(L, /data-drops="(\d+)"/)})`);
  const tagSpans = (/<div class="tags"[^>]*>([\s\S]*?)<\/div>/.exec(L) || [, ""])[1].match(/<span[^>]*>/g) || [];
  ok(tagSpans.length === e.groups.length && tagSpans.every(t => /left:/.test(t) && /visibility: visible/.test(t)), `${tag}: every group label is placed and shown on first paint (${tagSpans.filter(t => /left:/.test(t)).length}/${e.groups.length})`);
  ok(/data-pill="(Delayed|Closed) /.test(L), `${tag}: the pill says delayed or closed (${attr(L, /data-pill="([^"]*)"/)})`);
  const cards = [...L.matchAll(/<button[^>]*class="card" data-g="(\w+)"[\s\S]*?<div class="pct num"[^>]*>([^<]*)<\/div><div class="lvl">([^<]*)<\/div>/g)];
  ok(cards.length === e.groups.length, `${tag}: one card per group (${cards.length})`);
  for (const [, k, pct, when] of cards) {
    const g = e.groups.find(x => x.key === k);
    ok(g && pct === fmt(groupPct(g)), `${tag}: ${k} card ${pct} = recount ${g && fmt(groupPct(g))}`);
    if (g && g.members.every(M.econSlow)) ok(/^monthly · \w{3} \d{4}$/.test(when), `${tag}: the ${k} card (slow numbers only) shows its month, not "delayed" (${when})`);
    else ok(/^(delayed|closed)$/.test(when), `${tag}: ${k} card says delayed or closed (${when})`);
  }
  // r6: on the economy page too, each label hangs right under ITS blob (unless pushed below a neighbour) and is bright enough
  const eg = JSON.parse(dec(attr(L, /<div class="tags"[^>]*data-geo="([^"]*)"/) || "[]")).filter(Boolean);
  ok(eg.length === e.groups.length && eg.every(([top, low]) => top <= low && top >= low - 12), `${tag}: every economy-page label hangs right under its blob (${eg.map(g => g[0] + "/" + g[1]).join(" ")})`);
  ok(eg.every(g => g[2] >= 0.7), `${tag}: economy-page labels are bright enough to read (${eg.map(g => g[2]).join(" ")})`);
  ok(new RegExp(`class="tags"[^>]*>(<span[^>]*>[^<]+<\\/span>){${e.groups.length}}`).test(L), `${tag}: one label per blob (${e.groups.length})`);
  for (const K of keys) {
    const g = e.groups.find(x => x.key === K), H = dom(`g_${K}_${SIZE}`);
    ok(/<body class="incell"/.test(H), `${tag} ${K}: inside view is open`);
    ok(attr(H, /data-nodes="(\d+)"/) == g.members.length, `${tag} ${K}: ${g.members.length} blobs drawn (${attr(H, /data-nodes="(\d+)"/)})`);
    const rows = [...H.matchAll(/<li data-key="(\w+)">([\s\S]*?)<\/li>/g)];
    ok(rows.length === g.members.length, `${tag} ${K}: one list row per member (${rows.length})`);
    for (const [, key, inner] of rows) {
      const m = g.members.find(x => x.key === key), t = text(inner).map(dec);
      ok(m && t.includes(M.econMove(m.kind, m.prev, m.last).text), `${tag} ${K}/${key}: move text recounted (${t.join(" | ")})`);
      const lab = t[t.length - 1];
      if (m && M.econSlow(m)) ok(/^(weekly|monthly|quarterly|yearly) · /.test(lab) && !/delayed/.test(lab), `${tag} ${K}/${key}: a slow number shows its own date, never delayed (${lab})`);
      else ok(/^(delayed|closed) · /.test(lab) || (m && m.freq === "daily" && /^daily close · /.test(lab)), `${tag} ${K}/${key}: a price says delayed or closed with the time, or names its daily close (${lab})`);
    }
    const sub = dec(attr(H, /id="cellSub"[^>]*>([^<]*)</) || ""), gp = groupPct(g);
    const mvs = g.members.map(m => ({ m, mv: M.econMove(m.kind, m.prev, m.last) })), up = mvs.filter(x => x.mv.pct > 0).length;
    const against = (gp < 0 && up > g.members.length / 2) || (gp > 0 && up < g.members.length / 2);
    const drv = against ? mvs.slice().sort((a, b) => gp < 0 ? a.mv.pct - b.mv.pct : b.mv.pct - a.mv.pct)[0] : null;
    ok(drv ? sub.includes(`${drv.m.short || drv.m.name} ${drv.mv.text} pulls it ${gp < 0 ? "down" : "up"}`) : !/pulls it/.test(sub),
       `${tag} ${K}: subtitle names the member pulling the group against most of its members, recounted (${sub})`);
    const note = dec(attr(H, /<div class="notice on" id="notice">([^<]*)</) || "");   // the on-page note, not the help dialog's copy
    for (const x of e.missing.filter(z => z.group === K)) ok(note.includes(x.name) && note.includes(x.why), `${tag} ${K}: not-live ${x.name} is named on the page with its reason`);
  }
  // mm19: the front page carries every group as a blob, its move recounted here, and a label that opens it
  const F = dom("front_" + SIZE), fe = attr(F, /data-econ="([^"]*)"/) || "";
  const want = e.groups.map(g => [g.key, groupPct(g)]).filter(([, p]) => p != null);
  ok(fe === want.map(([k, p]) => k + ":" + p.toFixed(2)).join(","), `${tag} front: one economy blob per group, moves recounted (${fe})`);
  const doors = [...F.matchAll(/<span class="door econ" title="Look inside ([^"]+)"/g)].map(x => dec(x[1]));
  ok(doors.join() === e.groups.map(g => g.name).join(), `${tag} front: a label per group that opens it (${doors.join(" | ")})`);
  // Clark 10-01: two rows at every width, the economy BELOW the stocks, not one long row. Label heights are the
  // painted ones (style bottom:px): every economy label sits under every index label.
  const sp = (/<div class="tags"[^>]*>([\s\S]*?)<\/div>/.exec(F) || [, ""])[1].match(/<span[^>]*>/g) || [];
  const bOf = x => parseFloat((/bottom: ([\d.]+)px/.exec(x) || [, NaN])[1]);
  const idxB = sp.filter(x => !/door econ/.test(x)).map(bOf), ecoB = sp.filter(x => /door econ/.test(x)).map(bOf);
  ok(ecoB.length === e.groups.length && idxB.length >= 3 && Math.max(...ecoB) < Math.min(...idxB), `${tag} front: two rows, every economy label under every index label (economy tops ${Math.max(...ecoB)}px, index bottoms ${Math.min(...idxB)}px)`);
  // r3 design asks, measured on the page's own geometry (tags data-geo: label l, r, top, bottom | blob bottom, radius | font px)
  const geo = JSON.parse(dec(attr(F, /data-geo="([^"]*)"/) || "[]")).filter(Boolean);
  ok(geo.length === e.groups.length, `${tag} front: geometry for every economy label (${geo.length})`);
  for (const [l, r, top, , blobBot] of geo) ok(top <= blobBot && top >= blobBot - 16, `${tag} front: an economy label hangs right under ITS blob (label top ${top}px, blob bottom ${blobBot}px)`);
  for (let k = 1; k < geo.length; k++) ok(geo[k][0] >= geo[k - 1][1] || geo[k][3] >= geo[k - 1][2] || geo[k][2] <= geo[k - 1][3], `${tag} front: economy labels ${k - 1}/${k} do not overlap`);
  if (tag === "phone") ok(geo.every(g => g[5] >= 21.5 && g[6] >= 9), `${tag} front: economy blobs radius >= 22px, labels >= 9px (${geo.map(g => g[5] + "/" + g[6]).join(" ")})`);
  // r5: the economy row sits on its own shelf (a faint band + top hairline behind the wax): every economy blob and label inside it
  const shelf = (attr(F, /data-shelf="([^"]*)"/) || "").split(",").map(Number);
  ok(shelf.length === 2 && shelf[1] > shelf[0] && geo.every(([, , , bot, blobBot, R]) => bot >= shelf[0] && blobBot + 2 * R <= shelf[1]), `${tag} front: every economy blob and label sits on the economy shelf (${shelf.join("-")}px; ${geo.map(g => g[3] + "-" + (g[4] + 2 * g[5])).join(" ")})`);
  const Sm = dom("same_" + SIZE);
  ok(+attr(Sm, /data-shelf-line="(\d+)"/) >= 3, `${tag} front: the shelf's top hairline is drawn behind the row (${attr(Sm, /data-shelf-line="(\d+)"/)} of 9 points lit)`);
  ok(geo.every(g => g[7] >= 0.7), `${tag} front: economy labels are bright enough to read (luminance ${geo.map(g => g[7]).join(" ")})`);
  const bt = +attr(Sm, /data-bridge-tests="(\d+)"/), bb = +attr(Sm, /data-bridged="(\d+)"/);
  if (tag === "phone") ok(bt > 0 && bb === 0, `${tag} front: eight equal economy blobs a lane apart never bridge (${bb} of ${bt} close pairs fused)`);
  if (tag === "phone") ok(+attr(dom("samelamp_" + SIZE), /data-core-r="(\d+)"/) >= 28, `${tag}: at full size every economy blob is >= 28px radius, two rows of four (r3: eight 49px lanes left ~17px blobs) (${attr(dom("samelamp_" + SIZE), /data-core-r="(\d+)"/)}px)`);
  for (const [Lx, what] of [[L, "today's data"], [dom("samelamp_" + SIZE), "eight biggest blobs"]])
    ok(+attr(Lx, /data-edge-tests="(\d+)"/) > 0 && attr(Lx, /data-edge-hits="(\d+)"/) === "0", `${tag}: no economy blob is cut by the screen edge, ${what} (${attr(Lx, /data-edge-hits="(\d+)"/)} of ${attr(Lx, /data-edge-tests="(\d+)"/)} frames)`);
  const N = dom("no_" + SIZE);
  ok(/Couldn.t load the economy data/.test(N), `${tag}: no data file gives the honest notice`);
  ok(!/class="card"/.test(N) && !/data-drops=/.test(N), `${tag}: no data file draws no cards and no wax`);
}
const Sh = dom("short");   // a 568px phone: every blob drawn, none cut by an edge (two rows fall back to one when they cannot both move)
ok(attr(Sh, /data-drops="(\d+)"/) == 40 && +attr(Sh, /data-edge-tests="(\d+)"/) > 0 && attr(Sh, /data-edge-hits="(\d+)"/) === "0", `short phone: 8 blobs drawn, none cut by an edge (${attr(Sh, /data-drops="(\d+)"/)} drops, ${attr(Sh, /data-edge-hits="(\d+)"/)} of ${attr(Sh, /data-edge-tests="(\d+)"/)} frames)`);
console.log(`${bad ? "✘" : "✓"} economy-check: ${n} checks, ${bad} failed`); process.exit(bad ? 1 : 0);
EOJ
