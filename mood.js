/* mood.js — the pure rules that turn index numbers into the lamp's colour, height, size
   and speed. No DOM, no clock of its own: the page and check.js both load this file.
   Every rule here is one the "How to read it" panel states in words. */
(function (root) {
  "use strict";
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, t) => a + (b - a) * t;

  // colour = today's % change vs the previous close. Stops are [pct, [r,g,b]] (0..1).
  // Most days move well under 1%, so the scale saturates at ±1% to keep ordinary days distinct.
  const STOPS = [
    [-1.0, [0.78, 0.07, 0.29]],  // deep crimson  — falling hard
    [-0.35, [1.00, 0.36, 0.36]], // coral         — slipping
    [ 0.0, [1.00, 0.68, 0.22]],  // amber         — flat
    [ 0.35, [0.62, 0.90, 0.32]], // lime          — rising
    [ 1.0, [0.10, 0.85, 0.62]],  // mint-teal     — rising hard
  ];
  function colour(pct) {
    const p = clamp(pct, STOPS[0][0], STOPS[STOPS.length - 1][0]);
    for (let i = 1; i < STOPS.length; i++) {
      const [p1, c1] = STOPS[i];
      if (p <= p1) {
        const [p0, c0] = STOPS[i - 1];
        const t = (p - p0) / (p1 - p0);
        return [lerp(c0[0], c1[0], t), lerp(c0[1], c1[1], t), lerp(c0[2], c1[2], t)];
      }
    }
    return STOPS[STOPS.length - 1][1].slice();
  }

  // height: 0 = floor, 1 = ceiling. Up floats, down sinks; ±1% reaches the edge.
  const height = pct => 0.5 + 0.5 * clamp(pct, -1, 1);
  // size: a quiet index is a small blob, a big move (either way) is a big one.
  // A multiplier on the lane's base radius: 0.8 when flat, 1.4 at a 1.5% move or more.
  const size = pct => 0.8 + 0.6 * clamp(Math.abs(pct) / 1.5, 0, 1);

  // choppiness = spread of the last hour's 5-minute moves, in %. Speed 1 = a typical hour.
  const TYPICAL_5M = 0.08;
  function choppiness(closes, upto, window) {
    const w = window || 12, end = Math.min(upto, closes.length - 1), rets = [];
    for (let i = Math.max(1, end - w + 1); i <= end; i++) rets.push((closes[i] / closes[i - 1] - 1) * 100);
    if (rets.length < 2) return null;            // first minutes of the day: not enough to say
    const m = rets.reduce((a, b) => a + b, 0) / rets.length;
    return Math.sqrt(rets.reduce((a, b) => a + (b - m) * (b - m), 0) / (rets.length - 1));
  }
  const speed = chop => chop == null ? 1 : clamp(chop / TYPICAL_5M, 0.35, 3);
  const chopWord = chop => chop == null ? "just opened" : chop < TYPICAL_5M * 0.6 ? "steady" : chop < TYPICAL_5M * 1.6 ? "normal" : "choppy";

  // overall mood = the plain average of the four % changes.
  const MOODS = [[-1, "Fearful"], [-0.3, "Uneasy"], [0.3, "Calm"], [1, "Buoyant"], [Infinity, "Euphoric"]];
  function moodWord(avgPct) { for (const [hi, w] of MOODS) if (avgPct < hi) return w; }

  // live vs replay: live only while the NYSE regular session is open AND the data is fresh.
  // ponytail: no holiday calendar — on a holiday the data goes stale, so the page falls to replay.
  function marketState(nowMs, lastTimeSec) {
    const et = new Date(new Date(nowMs).toLocaleString("en-US", { timeZone: "America/New_York" }));
    const mins = et.getHours() * 60 + et.getMinutes(), day = et.getDay();
    const open = day >= 1 && day <= 5 && mins >= 570 && mins < 960;
    const ageMin = (nowMs / 1000 - lastTimeSec) / 60;
    if (open && ageMin <= 30) return { mode: "live", open, ageMin };   // the same 30 min the client is told
    return { mode: "replay", open, ageMin, stale: open };  // stale: open but the feed is behind
  }

  // price at a fractional bar position (replay glides between 5-minute closes).
  function priceAt(bars, pos) {
    const i = clamp(Math.floor(pos), 0, bars.length - 1), j = Math.min(i + 1, bars.length - 1);
    return lerp(bars[i][1], bars[j][1], clamp(pos - i, 0, 1));
  }

  // inside a blob the same rule with a wider reach: a single company moves more than an index
  // (half the S&P 500's members move over 1% on a normal day), so the top and bottom of the
  // cell are a 2.5% move — at ±1% half of them would pile against the walls.
  const heightIn = pct => 0.5 + 0.5 * clamp(pct / 2.5, -1, 1);
  // inside a blob: a member company moving the other way from its index. Both must move at
  // least 0.1% — on a flat day nothing is "against" anything.
  const against = (pct, idxPct) => Math.abs(pct) >= 0.1 && Math.abs(idxPct) >= 0.1 && Math.sign(pct) !== Math.sign(idxPct);
  // radii for weights (market value, or move) whose discs together cover `fill` of a circle of
  // radius R: area follows the weight, so a company twice the value gets twice the wax.
  function radii(weights, R, fill) {
    const sum = weights.reduce((a, b) => a + b, 0);
    if (!(sum > 0)) return weights.map(() => 0);
    const k = Math.sqrt(fill * R * R / sum);
    return weights.map(w => k * Math.sqrt(w));
  }
  // a member's move at a fractional bar position, from its basis-point series (see fetch.py)
  function movePct(bp, pos) {
    const i = clamp(Math.floor(pos), 0, bp.length - 1), j = Math.min(i + 1, bp.length - 1);
    return lerp(bp[i], bp[j], clamp(pos - i, 0, 1)) / 100;
  }

  // sectors as organs: sector labels aren't uniform across the page's own sources (Wikipedia's
  // GICS names vs nasdaq.com's screener labels) — normalised here, in the one place both the
  // Dow/S&P view and the Nasdaq view read sectors from (rule 1: one shared function).
  const SECTOR_ALIAS = { "Technology": "Information Technology", "Finance": "Financials",
    "Basic Materials": "Materials", "Telecommunications": "Communication Services",
    "Miscellaneous": "Other", "": "Other" };
  const normSector = s => SECTOR_ALIAS[s] || s;
  // a fixed left-to-right order so the same organ always lands in the same column inside every
  // cell, whatever subset of companies (top 50/100/500) is on screen that moment. Unknown/rare
  // sector names sort last, never dropped.
  const SECTOR_ORDER = ["Information Technology", "Health Care", "Financials",
    "Consumer Discretionary", "Communication Services", "Industrials", "Consumer Staples",
    "Energy", "Utilities", "Real Estate", "Materials"];
  function sectorRank(name) { const i = SECTOR_ORDER.indexOf(name); return i < 0 ? SECTOR_ORDER.length : i; }

  const api = { colour, height, size, choppiness, speed, chopWord, moodWord, marketState, priceAt,
                against, radii, movePct, heightIn, TYPICAL_5M, normSector, sectorRank, SECTOR_ORDER };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.Mood = api;
})(this);
