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

  // fear gauge: VIX's LEVEL (not its own daily move) says how nervous the market is. 12 or less
  // is fully calm (contributes nothing); 30+ is full fear. A normal ~16 day therefore reads about
  // 0.2 — visible, not saturated (the first 15..35 range left a normal day at 0.05, invisible).
  // ponytail: a fixed 12..30 band, not relative to the trailing VIX; upgrade = normalise against
  // the last N sessions' VIX closes once fetch.py stores more than the current session.
  const FEAR_LO = 12, FEAR_HI = 30;
  const fear = level => clamp((level - FEAR_LO) / (FEAR_HI - FEAR_LO), 0, 1);
  // the word the mood block prints beside the VIX level
  const fearWord = level => level < 14 ? "calm" : level < 20 ? "watchful" : level < 30 ? "nervous" : "fearful";

  // volume heartbeat: how heavy the last few bars traded relative to their own recent average —
  // 0 (still) when the market is shut (fewer than 2 real readings) or the average itself is 0,
  // 1 at double the recent average. Nulls (a bar with no volume reading) are dropped, not zeroed:
  // a missing reading must never read as a real, quiet moment (rule 6, same law as fetch.py's).
  function volumeLevel(vols) {
    const v = vols.filter(x => x != null && x > 0);
    if (v.length < 2) return 0;
    const avg = v.reduce((a, b) => a + b, 0) / v.length;
    return avg > 0 ? clamp(v[v.length - 1] / avg, 0, 2) / 2 : 0;
  }

  // heartbeat strength: the lamp's radius swings +-(1% + 5% x level). A normal beat (level 0.5) is
  // 3.5%, a busy one 6%, a quiet one ~2%. Exactly 0 when there is no volume reading (level 0):
  // a shut market is a hard, visible stillness, never a faint wobble.
  const pulseAmp = level => level > 0 ? 0.01 + 0.05 * clamp(level, 0, 1) : 0;
  const volumeWord = level => !(level > 0) ? "closed" : level < 0.35 ? "quiet" : level < 0.65 ? "normal" : "busy";

  // the day's shape as one series: mean move (%) of the given indexes at every bar, from their own
  // prev_close — what the scrubber's faint sparkline draws. Fewer bars than any index has = the
  // shortest one, so a ragged index never yields NaN.
  function avgSeries(indexes) {
    const n = Math.min(...indexes.map(ix => ix.bars.length));
    return Array.from({ length: n }, (_, k) => indexes.reduce((a, ix) => a + (ix.bars[k][1] / ix.prev_close - 1) * 100, 0) / indexes.length);
  }

  // short tags for phone width — whole words, never a slice (a sliced tag reads as "Eng")
  const SECTOR_SHORT = { "Information Technology": "Tech", "Consumer Discretionary": "Cons. Disc.",
    "Consumer Staples": "Staples", "Communication Services": "Comm.", "Health Care": "Health", "Real Estate": "Real Est." };
  const sectorShort = name => SECTOR_SHORT[name] || name;

  // a stable identity hue per sector (degrees), from its fixed rank: an organ's halo keeps its
  // colour whatever the day's move does to the blobs inside it.
  const sectorHue = name => (sectorRank(name) * 137.5 + 200) % 360;

  // scrubber: a fraction of the track (0..1) -> the nearest whole bar index. The same function
  // drives both a real pointer drag and the page's own #scrub= test hook, so what the mouse does
  // and what a link does are provably the same rule (rule 2: nothing to verify twice, separately).
  const scrubPos = (frac, nBars) => clamp(Math.round(clamp(frac, 0, 1) * (nBars - 1)), 0, nBars - 1);


  // ---------- the economy: grouped blobs (energy, metals, farm goods, rates, the slow macro numbers) ----------
  // A member's move is measured the way its own market measures it, then turned into a "percent-
  // equivalent" so the SAME colour / height / size rules above apply unchanged:
  //   pct  = percent change of the level (oil, gold, corn, CPI, sales...)
  //   bp   = change of a rate in basis points; 10 bp counts as 1% (yields, mortgage rates)
  //   pt   = change of a rate in percentage points; 0.1 pt counts as 1% (unemployment)
  //   jobs = change in thousands of jobs; 150k counts as 1% (payrolls)
  // Colour follows the DIRECTION of the number, not whether it is good news (rising unemployment is
  // green-up here, like rising oil); the page's help says so.
  const MINUS = "\u2212";
  const signed = (v, digits, unit) => { const r = +v.toFixed(digits); return (r > 0 ? "+" : r < 0 ? MINUS : "") + Math.abs(r).toFixed(digits) + unit; };   // -0.3 bp rounds to "0 bp", never "-0 bp"
  function econMove(kind, prev, last) {
    if (!(isFinite(prev) && isFinite(last))) return null;
    if (kind === "pct") { if (!(prev > 0)) return null; const d = (last / prev - 1) * 100; return { raw: d, pct: d, text: signed(d, 2, "%") }; }
    if (kind === "bp") { const d = (last - prev) * 100; return { raw: d, pct: d / 10, text: signed(d, 0, " bp") }; }
    if (kind === "pt") { const d = last - prev; return { raw: d, pct: d * 10, text: signed(d, 1, " pt") }; }
    if (kind === "jobs") { const d = last - prev; return { raw: d, pct: d / 150, text: signed(d, 0, "k jobs") }; }
    // ponytail: a $5 bn swing counts as 1% (a scale like payrolls' 150k); the trade balance is negative, so a
    // percent change would flip its meaning. Input in $ million (FRED BOPGSTB). Upgrade: scale by its own spread.
    if (kind === "bn") { const d = (last - prev) / 1000; return { raw: d, pct: d / 5, text: (d > 0 ? "+$" : d < 0 ? MINUS + "$" : "$") + Math.abs(+d.toFixed(1)).toFixed(1) + " bn" }; }
    return null;
  }
  // slow = a weekly or monthly release: no last hour to be choppy in, and it never moves between releases
  const econSlow = m => m.freq === "weekly" || m.freq === "monthly" || m.freq === "quarterly" || m.freq === "yearly";
  // the last hour's choppiness of a market-traded member, in the same units as its move (so a yield
  // and an oil future are judged by the same rule): the spread of bar-to-bar moves of its
  // percent-equivalent path over the last ~hour of prints. null when fewer than 4 prints fall in that
  // hour (a thin market, a closed one, a monthly number): "no reading", never "steady".
  function econChop(m) {
    if (!m.bars || m.bars.length < 4) return null;
    const end = m.bars[m.bars.length - 1][0], hour = m.bars.filter(b => b[0] >= end - 3900);
    if (hour.length < 4) return null;
    const path = hour.map(b => { const e = econMove(m.kind, m.prev, b[1]); return e ? 100 + e.pct : NaN; });
    return path.some(v => !isFinite(v)) ? null : choppiness(path, path.length - 1, path.length);
  }
  // a group's move = the plain average of its members' percent-equivalents; a group with market-
  // traded members averages only those (a monthly reading from weeks ago is not today's move);
  // a group made only of slow numbers (the economy blob) averages them all, each at its own date.
  function econGroupPct(moves) {
    const ok = moves.filter(x => x && x.move);
    const fast = ok.filter(x => !econSlow(x.m)), use = fast.length ? fast : ok;
    return use.length ? use.reduce((a, x) => a + x.move.pct, 0) / use.length : null;
  }
  // where a reading stands in time, in words the page prints as-is. Never says "live" for a number
  // that is not: a market-traded member is "delayed" only while its last print is under 45 minutes old.
  function econAsOf(m, nowMs) {
    const tz = { timeZone: "America/New_York" }, d = new Date(m.asof + "T12:00:00Z");
    const day = (o) => d.toLocaleDateString("en-US", Object.assign({ timeZone: "UTC" }, o));
    if (m.freq === "monthly") return { slow: true, live: false, label: "monthly \u00b7 " + day({ month: "short", year: "numeric" }) };
    if (m.freq === "quarterly") return { slow: true, live: false, label: "quarterly \u00b7 Q" + (Math.floor(+m.asof.slice(5, 7) / 3) + 1) + " " + m.asof.slice(0, 4) };
    if (m.freq === "yearly") return { slow: true, live: false, label: "yearly \u00b7 " + m.asof.slice(0, 4) };
    if (m.freq === "weekly") return { slow: true, live: false, label: "weekly \u00b7 " + day({ month: "short", day: "numeric" }) };
    if (m.freq === "daily") return { slow: false, live: false, label: "daily close \u00b7 " + day({ month: "short", day: "numeric" }) };
    const age = (nowMs / 1000 - m.last_time) / 60, t = new Date(m.last_time * 1000);
    const clock = t.toLocaleTimeString("en-US", Object.assign({ hour: "numeric", minute: "2-digit" }, tz)) + " ET";
    if (age <= 45) return { slow: false, live: true, label: "delayed \u00b7 " + clock };
    const dow = t.toLocaleDateString("en-US", Object.assign({ weekday: "short" }, tz));
    return { slow: false, live: false, label: "closed \u00b7 as of " + dow + " " + clock };
  }

  const api = { colour, height, size, choppiness, speed, chopWord, moodWord, marketState, priceAt,
                against, radii, movePct, heightIn, TYPICAL_5M, normSector, sectorRank, SECTOR_ORDER,
                fear, fearWord, volumeLevel, pulseAmp, volumeWord, avgSeries, sectorHue, sectorShort, scrubPos,
                econMove, econChop, econSlow, econGroupPct, econAsOf };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.Mood = api;
})(this);
