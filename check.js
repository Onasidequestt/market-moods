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
console.log(`✓ market-moods check: ${n} asserts`);
