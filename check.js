#!/usr/bin/env node
// check.js — asserts the lamp's rules (mood.js) and the shape of data/market.json.
// usage: node check.js        exits 1 on the first broken rule
"use strict";
const assert = require("assert");
const fs = require("fs"), path = require("path");
const M = require("./mood.js");
let n = 0;
const ok = (c, msg) => { assert.ok(c, msg); n++; };
const near = (a, b, msg) => ok(Math.abs(a - b) < 1e-9, `${msg}: ${a} != ${b}`);

// colour: amber when flat, red falling, green rising, clamped past ±1%
const [fr, fg] = M.colour(0);
ok(fr === 1 && fg > 0.6 && fg < 0.75, "flat is amber");
ok(M.colour(-1)[0] > M.colour(1)[0] && M.colour(1)[1] > M.colour(-1)[1], "down is redder, up is greener");
near(M.colour(-9)[1], M.colour(-1)[1], "colour clamps below -1%");
near(M.colour(9)[2], M.colour(1)[2], "colour clamps above +1%");
ok(M.colour(-0.9)[1] > M.colour(-1)[1] + 0.01, "colour still changes just inside -1%");

// height: up floats, down sinks, ±1% reaches the edges
near(M.height(0), 0.5, "flat sits mid-lamp");
near(M.height(1), 1, "+1% at the top"); near(M.height(-1), 0, "-1% at the floor");
near(M.height(0.5), 0.75, "+0.5% three-quarters up");
ok(M.height(0.9) > M.height(0.5), "a bigger rise floats higher");

// size: symmetric in the move, bigger move = bigger blob
near(M.size(0), 0.8, "flat size"); near(M.size(-0.7), M.size(0.7), "size ignores direction");
near(M.size(5), 1.4, "size caps at a 1.5% move"); near(M.size(0.75), 1.1, "half-way size at 0.75%");

// choppiness: sample stdev of 5-min % moves; null until there are 2 moves
ok(M.choppiness([100, 101], 1) === null, "one move is not enough");
near(M.choppiness([100, 100, 100, 100], 3), 0, "flat line has zero chop");
const c = M.choppiness([100, 101, 100, 101], 3);           // +1%, -0.990%, +1%
ok(c > 1.1 && c < 1.2, "chop of a zigzag ≈ 1.15%: " + c);
ok(M.chopWord(null) === "just opened" && M.chopWord(0.01) === "steady" && M.chopWord(0.3) === "choppy", "chop words");
ok(M.speed(null) === 1 && M.speed(0) === 0.35 && M.speed(9) === 3, "speed clamps");

// mood word
const words = [-1.2, -0.5, 0, 0.5, 1.2].map(M.moodWord).join(",");
ok(words === "Fearful,Uneasy,Calm,Buoyant,Euphoric", "mood words: " + words);
const edges = [-1.01, -1, -0.99, -0.31, -0.3, -0.29, 0.29, 0.3, 0.99, 1].map(M.moodWord).join(",");
ok(edges === "Fearful,Uneasy,Uneasy,Uneasy,Calm,Calm,Calm,Buoyant,Buoyant,Euphoric", "mood edges: " + edges);

// market state (times are ET; September = EDT = UTC-4)
const et = (s) => Date.parse(s + "-04:00");
const sec = (s) => et(s) / 1000;
ok(M.marketState(et("2026-09-25T14:00:00"), sec("2026-09-25T13:55:00")).mode === "live", "Fri 2pm fresh = live");
const sat = M.marketState(et("2026-09-26T14:00:00"), sec("2026-09-25T16:00:00"));
ok(sat.mode === "replay" && !sat.stale, "Saturday = replay, not stale");
const behind = M.marketState(et("2026-09-25T14:00:00"), sec("2026-09-25T12:00:00"));
ok(behind.mode === "replay" && behind.stale, "open but 2h behind = replay, stale");
ok(M.marketState(et("2026-09-25T09:29:00"), sec("2026-09-24T16:00:00")).mode === "replay", "9:29 is before the bell");
ok(M.marketState(et("2026-09-25T14:00:00"), sec("2026-09-25T13:30:00")).mode === "live", "30 min old is still live");
ok(M.marketState(et("2026-09-25T14:00:00"), sec("2026-09-25T13:29:00")).stale, "31 min old is behind, not live");
ok(M.marketState(et("2026-09-25T16:00:00"), sec("2026-09-25T15:55:00")).mode === "replay", "4:00 is after the bell");

// replay glides between closes
near(M.priceAt([[0, 100], [1, 110]], 0.5), 105, "halfway between bars");
near(M.priceAt([[0, 100], [1, 110]], 7), 110, "past the end holds the close");

// inside a blob: against, radii, member moves
ok(M.against(-1.2, 0.5) && M.against(0.3, -0.2), "a company moving the other way is against its index");
ok(!M.against(0.5, 0.5) && !M.against(-0.3, -1), "same direction is not against");
ok(!M.against(-0.05, 0.8) && !M.against(-2, 0.05), "under 0.1% either side: not against (flat is not a direction)");
const rr = M.radii([4, 1, 1], 10, 0.6);
near(rr[0], 2 * rr[1], "area follows weight: 4x the value = 2x the radius");
near(rr.reduce((a, r) => a + r * r, 0), 0.6 * 100, "the discs cover the asked share of the circle");
ok(M.radii([0, 0], 10, 0.5).every(r => r === 0), "no weight, no wax");
near(M.movePct([0, 100, 300], 1.5), 2, "member move glides between bars (basis points -> %)");
near(M.movePct([0, 100], 9), 1, "past the end holds the last bar");
near(M.heightIn(0), 0.5, "inside: flat mid-cell"); near(M.heightIn(2.5), 1, "inside: +2.5% at the top");
near(M.heightIn(-1.25), 0.25, "inside: -1.25% a quarter up"); near(M.heightIn(-9), 0, "inside: clamps at the floor");

// sectors as organs: sector names get normalised to one shared vocabulary, and sort into a
// fixed, stable column order regardless of which source a company's raw label came from
ok(M.normSector("Technology") === "Information Technology", "nasdaq's 'Technology' joins the same organ as 'Information Technology'");
ok(M.normSector("Finance") === "Financials" && M.normSector("Basic Materials") === "Materials", "sector aliases normalise");
ok(M.normSector("Health Care") === "Health Care", "an already-canonical sector passes through unchanged");
ok(M.sectorRank("Information Technology") === 0, "Information Technology organ is first");
ok(M.sectorRank("Materials") === M.SECTOR_ORDER.length - 1, "Materials organ is last of the known order");
ok(M.sectorRank("Something Unheard Of") === M.SECTOR_ORDER.length, "an unknown sector sorts after every known one, never dropped");

// fear gauge: VIX level -> a 0..1 fear factor; calm is inert, high VIX saturates at 1
near(M.fear(12), 0, "VIX 12 (calm) contributes no fear");
near(M.fear(30), 1, "VIX 30+ is full fear");
near(M.fear(21), 0.5, "VIX 21 is half-way to full fear");
near(M.fear(5), 0, "fear clamps at the floor, never negative");
near(M.fear(60), 1, "fear clamps at the ceiling");
ok(M.fear(16) > 0.2, "a NORMAL day (VIX 16) reads a visible fear (>0.2), not 0.05");
ok(M.fearWord(11) === "calm" && M.fearWord(16) === "watchful" && M.fearWord(25) === "nervous" && M.fearWord(40) === "fearful", "fear words by VIX band");
near(M.pulseAmp(0), 0, "no volume: the heartbeat amplitude is exactly 0 (hard still)");
ok(M.pulseAmp(0.5) >= 0.03 && M.pulseAmp(0.5) <= 0.04, "a normal beat is 3-4% of the radius");
ok(M.pulseAmp(1) >= 0.05 && M.pulseAmp(0.05) > 0.01, "busy beats harder, even a quiet market still moves > 1%");
ok(M.volumeWord(0) === "closed" && M.volumeWord(0.2) === "quiet" && M.volumeWord(0.5) === "normal" && M.volumeWord(0.9) === "busy", "volume words");
{ const s = M.avgSeries([{ prev_close: 100, bars: [[0, 101], [1, 102], [2, 103]] }, { prev_close: 200, bars: [[0, 200], [1, 198]] }]);
  ok(s.length === 2 && Math.abs(s[0] - 0.5) < 1e-9 && Math.abs(s[1] - 0.5) < 1e-9, "avgSeries: mean move per bar, shortest index sets the length"); }
const SECS_SHORT_OK = () => M.SECTOR_ORDER.every(x => M.sectorShort(x).length <= 12);
ok(M.sectorShort("Information Technology") === "Tech" && M.sectorShort("Energy") === "Energy" && SECS_SHORT_OK(), "phone tags are whole words, never a slice");
ok(M.sectorHue("Energy") !== M.sectorHue("Utilities") && M.sectorHue("Energy") === M.sectorHue("Energy"), "sector identity hues are stable and distinct");

// volume heartbeat: 0..1, relative to the bars' own recent average; shut/no-data market is still
ok(M.volumeLevel([]) === 0, "no volume readings: the lamp stays still (market shut)");
ok(M.volumeLevel([0, 0, 0]) === 0, "all-zero volume: still, not a fake pulse");
ok(M.volumeLevel([null, null, 100]) === 0, "one real reading is not enough to say anything");
near(M.volumeLevel([100, 100, 100]), 0.5, "trading exactly at its own recent average is a normal, half-strength beat");
near(M.volumeLevel([100, 100, 400]), 1, "double the recent average caps the pulse at its strongest");
ok(M.volumeLevel([null, 100, 100, 300]) > 0.5, "a null reading is dropped from the average, not counted as zero");

// scrubber: a track fraction -> the nearest whole bar, shared by a real drag and the #scrub= link
ok(M.scrubPos(0, 79) === 0, "the far left of the track is the first bar");
ok(M.scrubPos(1, 79) === 78, "the far right of the track is the last bar");
ok(M.scrubPos(0.5, 11) === 5, "the middle of an 11-bar track lands on bar 5");
ok(M.scrubPos(-0.4, 10) === 0 && M.scrubPos(1.4, 10) === 9, "a drag past either edge clamps to it, never falls off the track");

// the data file the page reads
const f = path.join(__dirname, "data", "market.json");
const d = JSON.parse(fs.readFileSync(f, "utf8"));
ok(d.indexes.map(i => i.key).join() === "dow,sp500,nasdaq,russell", "four indexes in lane order");
for (const i of d.indexes) {
  ok(i.bars.length >= 2 && i.prev_close > 0, i.key + ": bars and a previous close");
  ok(i.bars.every((b, k) => k === 0 || b[0] > i.bars[k - 1][0]), i.key + ": bars in time order");
  ok(i.last === i.bars[i.bars.length - 1][1] && i.last_time === i.bars[i.bars.length - 1][0], i.key + ": last = final bar");
  ok(Math.abs(i.last / i.prev_close - 1) < 0.15, i.key + ": move under 15% (a bad close would show here)");
}
ok(new Set(d.indexes.map(i => i.session_date)).size === 1, "all four from the same session");
// the fear gauge (VIX) is optional in the data file — its absence is an honest empty state (the
// page runs the lamp with no fear effect), never faked; when present it must be real, priced data
if (d.vix) ok(d.vix.key === "vix" && d.vix.last > 0 && d.vix.bars.length >= 2, "vix: real, priced data when present");
else console.log("… data/market.json has no vix field: the fear gauge is off (honest, not faked)");
// sessions: the past week's real days for replay, oldest first, the last one = the top-level session
const dates = d.indexes[0].sessions.map(x => x.date);
ok(dates.length >= 2 && dates.every((x, k) => k === 0 || x > dates[k - 1]), "sessions oldest first: " + dates);
for (const i of d.indexes) {
  ok(i.sessions.map(x => x.date).join() === dates.join(), i.key + ": same days as the Dow");
  const L = i.sessions[i.sessions.length - 1];
  ok(L.date === i.session_date && L.prev_close === i.prev_close && L.bars.length === i.bars.length, i.key + ": last session = top level");
  for (let k = 1; k < i.sessions.length; k++) {
    const prev = i.sessions[k - 1], cur = i.sessions[k];
    // a day's prev_close is the day before's close; its last 5-min bar sits within 0.3% of that close
    ok(Math.abs(cur.prev_close / prev.bars[prev.bars.length - 1][1] - 1) < 0.003, `${i.key} ${cur.date}: prev_close follows ${prev.date}`);
  }
}
// the companies inside each index's blob (data/companies.json for sp500, data/companies-<key>.json
// for the other three, all written by fetch.py --companies <key>). A missing file is honest, not a
// failure: the page shows no door for that index rather than faking one (rule 6).
const CELL_FILE = { dow: "companies-dow.json", sp500: "companies.json", nasdaq: "companies-nasdaq.json", russell: "companies-russell.json" };
const CELL_MIN = { dow: 27, sp500: 450, nasdaq: 400, russell: 400 };   // mirrors fetch.py's MIN_PRICED
const CELL_EXACT = { dow: 30 };   // the Dow must show ALL 30, never a subset (rule: never pad, never truncate)
let anyCompanies = false;
for (const key of Object.keys(CELL_FILE)) {
  const cf = path.join(__dirname, "data", CELL_FILE[key]);
  if (!fs.existsSync(cf)) { console.log(`… ${CELL_FILE[key]} missing: ${key}'s inside view has no door (honest, not built yet)`); continue; }
  anyCompanies = true;
  const co = JSON.parse(fs.readFileSync(cf, "utf8"));
  ok(co.index === key && co.companies.length >= (CELL_EXACT[key] || 400), `${key}: has its members (${co.companies.length})`);
  if (CELL_EXACT[key]) ok(co.companies.length === CELL_EXACT[key], `${key}: shows all ${CELL_EXACT[key]}, never a subset (${co.companies.length})`);
  ok(co.companies.every((c, k) => c.s && c.n && c.cap > 0 && (k === 0 || c.cap <= co.companies[k - 1].cap)), `${key}: companies biggest first, each named with a value`);
  ok(new Set(co.companies.map(c => c.s)).size === co.companies.length, `${key}: no company twice`);
  const ix = d.indexes.find(i => i.key === key);
  const cdates = co.sessions.map(x => x.date);
  ok(cdates.every((x, k) => k === 0 || x > cdates[k - 1]), `${key}: company days oldest first: ${cdates}`);
  for (const S of co.sessions) {
    ok(S.m.length === co.companies.length, `${key} ${S.date}: one row per company`);
    ok(S.m.every(r => r === null || (r.length === S.t.length && r.every(v => Number.isInteger(v) && Math.abs(v) < 5000))), `${key} ${S.date}: rows on the day's clock, whole bp, under 50%`);
    const same = ix && ix.sessions.find(x => x.date === S.date);
    // on the index's own clock (today's company file may trail the index by one fetch: a prefix).
    // Mid-session Yahoo's newest bar is stamped with the fetch time (e.g. 14:18:49), and a later fetch
    // replaces it with the regular 5-min bar (14:20): so a company file's LAST bar may be such an
    // in-progress bar, lying inside the index's bar at that slot. The companies refresh every 30 min
    // and the index every 10, so without this the index workflow went red between company runs.
    if (same) ok(S.t.length <= same.bars.length && S.t.every((t, k) => t === same.bars[k][0] ||
        (k === S.t.length - 1 && k > 0 && t > same.bars[k - 1][0] && t < same.bars[k][0])), `${key} ${S.date}: company clock = ${key}'s bar times`);
  }
  const lastC = co.sessions[co.sessions.length - 1];
  ok(lastC.m.filter(Boolean).length >= CELL_MIN[key], `${key} ${lastC.date}: at least ${CELL_MIN[key]} companies priced (${lastC.m.filter(Boolean).length})`);
}
ok(anyCompanies, "at least one index has its companies file (else nothing to check)");
// the "How to read it" copy may only name an index as having companies inside if its file exists
// (critic 09-28: the help said "every index" while the Russell had no file and no door)
{
  const page = fs.readFileSync(path.join(__dirname, "index.html"), "utf8");
  const inside = (page.match(/<dt>Inside<\/dt><dd>([\s\S]*?)<\/dd>/) || [])[1] || "";
  ok(inside, "help dialog has an Inside entry");
  const NAME = { dow: "Dow", sp500: "S&amp;P 500", nasdaq: "Nasdaq", russell: "Russell 2000" };
  const claim = inside.split(/[.(]/)[0];   // the first sentence, before any aside, names who has companies
  for (const key of Object.keys(CELL_FILE)) {
    const has = fs.existsSync(path.join(__dirname, "data", CELL_FILE[key]));
    if (!has) ok(!claim.includes(NAME[key]) && !/every index/i.test(inside), `help must not claim ${key} has companies inside (no ${CELL_FILE[key]})`);
    else ok(claim.includes(NAME[key]), `help names ${key} as having companies inside`);
  }
}

const FRESH = process.argv.includes("--fresh");   // economy.yml only: also fail on a stale economy file
// ---------- the economy blobs (economy.html, data/economy.json, mood.js econ*) ----------
// rules: a move is measured the way its market measures it, then turned into a percent-equivalent
near(M.econMove("pct", 100, 98.5).pct, -1.5, "econ pct: percent change of the level");
near(M.econMove("bp", 5.00, 5.06).raw, 6, "econ bp: a rate's change in basis points");
near(M.econMove("bp", 5.00, 5.10).pct, 1, "econ bp: 10 bp counts as 1%");
ok(M.econMove("bp", 5.068, 5.063).text === "0 bp", "econ bp: a move that rounds to 0 reads 0 bp, never -0 bp");
near(M.econMove("pt", 4.1, 4.2).pct, 1, "econ pt: 0.1 point counts as 1%");
near(M.econMove("jobs", 100000, 100150).pct, 1, "econ jobs: 150k jobs counts as 1%");
ok(M.econMove("pct", 0, 5) === null && M.econMove("bp", NaN, 5) === null && M.econMove("nope", 1, 2) === null, "econ: no move rather than a made-up one");
ok(M.econMove("bp", 5, 5.06).text === "+6 bp" && M.econMove("pct", 100, 98.5).text === "−1.50%" && M.econMove("jobs", 1, 163).text === "+162k jobs", "econ: the words say the unit");
ok(M.econSlow({ freq: "monthly" }) && M.econSlow({ freq: "weekly" }) && !M.econSlow({ freq: "5min" }) && !M.econSlow({ freq: "daily" }), "econ: weekly and monthly are slow");
{ // a group of market prices averages only the prices; slow numbers only enter a group made of nothing else
  const mv = (freq, pct) => ({ m: { freq }, move: { pct } });
  near(M.econGroupPct([mv("5min", 1), mv("5min", 3), mv("monthly", -9)]), 2, "econ group: the old monthly number is not today's move");
  near(M.econGroupPct([mv("monthly", 1), mv("weekly", 3)]), 2, "econ group: an all-slow group averages its slow numbers");
  ok(M.econGroupPct([]) === null && M.econGroupPct([{ m: { freq: "5min" }, move: null }]) === null, "econ group: no members, no move");
}
{ // honesty of time: "delayed" only for a fresh print of a market, never for a slow number
  const now = Date.parse("2026-09-28T20:00:00Z"), t = now / 1000;
  const fresh = M.econAsOf({ freq: "5min", last_time: t - 600, asof: "2026-09-28" }, now);
  ok(fresh.live && /^delayed/.test(fresh.label), "econ time: a print 10 minutes old is delayed, not closed");
  const old = M.econAsOf({ freq: "5min", last_time: t - 3 * 3600, asof: "2026-09-28" }, now);
  ok(!old.live && /^closed · as of /.test(old.label), "econ time: a 3-hour-old print says closed and when");
  const mo = M.econAsOf({ freq: "monthly", asof: "2026-08-01", last_time: t }, now);
  ok(!mo.live && mo.slow && mo.label === "monthly · Aug 2026", "econ time: a monthly number shows its month, even with a fresh last_time");
  ok(M.econAsOf({ freq: "weekly", asof: "2026-09-24" }, now).label === "weekly · Sep 24", "econ time: a weekly number shows its date");
  ok(!M.econAsOf({ freq: "daily", asof: "2026-09-28", last_time: t }, now).live, "econ time: a daily close is never live");
}
{ // motion: only a real last hour is choppy; a thin or shut market is null, not steady
  ok(M.econChop({ kind: "pct", prev: 100, bars: [[1000, 100], [1300, 101]] }) === null, "econ chop: two prints is not a last hour");
  const steady = { kind: "pct", prev: 100, bars: [0, 1, 2, 3, 4, 5].map(k => [1000 + k * 300, 100 + k * 0.01]) };
  const wild = { kind: "pct", prev: 100, bars: [0, 1, 2, 3, 4, 5].map(k => [1000 + k * 300, 100 + (k % 2 ? 1 : -1)]) };
  ok(M.econChop(wild) > M.econChop(steady), "econ chop: swinging prints are choppier than a drift");
  ok(M.econChop({ kind: "pct", prev: 100, bars: [[0, 100], [300, 101], [600, 100], [900, 101], [20000, 100]] }) === null, "econ chop: prints from hours ago are not the last hour");
}
// data: real numbers or an honest missing list
{
  const ef = path.join(__dirname, "data", "economy.json");
  if (!fs.existsSync(ef)) console.log("… data/economy.json missing: the economy page shows its honest 'couldn't load' notice");
  else {
    const e = JSON.parse(fs.readFileSync(ef, "utf8")), today = Date.now() / 1000, day = 86400;
    ok(e.groups.map(g => g.key).join() === "energy,metals,farm,rates,macro", "economy: the five groups, in order: " + e.groups.map(g => g.key));
    const seen = new Set(), all = [];
    for (const g of e.groups) {
      ok(g.members.length >= 3, `${g.key}: at least 3 members live (${g.members.length})`);
      for (const m of g.members) {
        ok(!seen.has(m.key), `${m.key}: not in two groups`); seen.add(m.key); all.push(m);
        ok(["pct", "bp", "pt", "jobs"].includes(m.kind) && ["5min", "daily", "weekly", "monthly"].includes(m.freq), `${m.key}: known kind and rhythm`);
        ok(Number.isFinite(m.prev) && Number.isFinite(m.last) && m.name && m.unit && m.src && m.short, `${m.key}: real numbers, named, with unit and source`);
        const mv = M.econMove(m.kind, m.prev, m.last);
        ok(mv && Math.abs(mv.pct) < 30, `${m.key}: a move exists and is under 30% (${mv && mv.text}): a bigger one is a parse bug, not news`);
        ok(/^\d{4}-\d{2}-\d{2}$/.test(m.asof), `${m.key}: dated`);
        const age = (today - Date.parse(m.asof + "T12:00:00Z") / 1000) / day;
        const limit = { "5min": 10, daily: 10, weekly: 21, monthly: 100 }[m.freq];
        // staleness is only a failure where the economy file is what is being refreshed (economy.yml passes
        // --fresh); in the index and companies workflows an old economy file must not block stock data
        if (FRESH) ok(age >= -1 && age <= limit, `${m.key}: ${m.freq} number dated ${m.asof} is ${age.toFixed(0)} days old, limit ${limit}`);
        else { ok(age >= -1, `${m.key}: not dated in the future`); if (age > limit) console.log(`\u2026 ${m.key} is ${age.toFixed(0)} days old (limit ${limit}); economy.yml would fail on this`); }
        if (M.econSlow(m)) ok(m.prev_asof && m.prev_asof < m.asof, `${m.key}: a slow number names the reading before it`);
        else ok(m.last_time > today - 10 * day && m.last_time < today + 3600, `${m.key}: last print time is real`);
        if (m.freq === "5min") ok(m.bars.length >= 1 && m.bars[m.bars.length - 1][0] === m.last_time && m.bars[m.bars.length - 1][1] === m.last, `${m.key}: the newest bar IS the last price`);
      }
    }
    // everything Clark named is either live or listed as missing WITH a reason: nothing silently dropped
    const asked = { brent: "Brent", wti: "WTI", natgas: "gas", gold: "Gold", silver: "Silver", copper: "Copper", steel: "steel", cobalt: "Cobalt",
      corn: "Corn", soy: "Soybeans", cotton: "Cotton", coffee: "Coffee", wheat: "Wheat", t10y: "10-year", mortgage: "mortgage", sentiment: "sentiment",
      payrolls: "Jobs", spending: "spending", cpi: "Consumer prices", unemp: "Unemployment", retail: "Retail" };
    for (const [key, word] of Object.entries(asked)) {
      const live = seen.has(key), miss = e.missing.find(x => x.name.toLowerCase().includes(word.toLowerCase()));
      ok(live || (miss && miss.why.length > 10), `asked-for ${key}: live, or missing with a reason`);
      ok(!(live && miss), `${key}: not both live and missing`);
    }
    ok(e.missing.every(x => x.group && x.name && x.why), "economy: every missing series says which group, what, and why");
    ok(all.length >= 20, `economy: ${all.length} series live`);
  }
  // the page reads only this file and invents no numbers
  const page = fs.readFileSync(path.join(__dirname, "economy.html"), "utf8");
  ok(page.includes('DATA_URL = "data/economy.json"') && !/Math\.random/.test(page), "economy.html: reads data/economy.json only, no random numbers");
  ok(/<dt>Dates<\/dt>/.test(page) && /never called live/.test(page), "economy.html: help says slow numbers carry their own date");
}
console.log(`✓ market-moods check: ${n} asserts`);
