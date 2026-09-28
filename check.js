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
console.log(`✓ market-moods check: ${n} asserts`);
