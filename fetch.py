#!/usr/bin/env python3
"""fetch.py — pull the four US index series into data/market.json for the page.

Source: Yahoo Finance's public chart endpoint (no key). Index levels arrive delayed
(Yahoo marks US indexes real-time-ish, but we promise only "delayed ~15 min").
Writes one file:
  data/market.json = {generated_at, source, indexes:[{key,name,symbol,session_date,
                      prev_close, last, last_time, bars:[[unix, close], ...]}]}
`bars` = every 5-minute close of the MOST RECENT session; `prev_close` = the official
daily close of the session before it. The page decides live vs replay from last_time.

ponytail: Yahoo's endpoint is unofficial and can change or rate-limit. Ceiling: fine for a
prototype polled every 10 min by one GitHub Action. Upgrade path: a licensed feed
(Polygon/Finnhub/IEX) on the client's own host, where the key stays server-side.

usage: fetch.py [--out data/market.json] | fetch.py --selfcheck
"""
import json, pathlib, sys, time, urllib.request
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

INDEXES = [("dow", "Dow Jones", "^DJI"), ("sp500", "S&P 500", "^GSPC"),
           ("nasdaq", "Nasdaq", "^IXIC"), ("russell", "Russell 2000", "^RUT")]
ET = ZoneInfo("America/New_York")
URL = "https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval={iv}&range={rng}"

def get(sym, iv, rng):
    req = urllib.request.Request(URL.format(sym=sym.replace("^", "%5E"), iv=iv, rng=rng),
                                 headers={"User-Agent": "Mozilla/5.0 market-moods"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)["chart"]["result"][0]

def pairs(res):
    ts, cl = res.get("timestamp") or [], res["indicators"]["quote"][0]["close"]
    return [(t, c) for t, c in zip(ts, cl) if c is not None]

def shape(key, name, sym, intraday, daily):
    """Pure: last session's 5-min bars + the official close of the session before it."""
    bars = pairs(intraday)
    if not bars: raise ValueError(f"{sym}: no intraday bars")
    day = lambda t: datetime.fromtimestamp(t, ET).date()
    last_day = day(bars[-1][0])
    session = [(t, round(c, 2)) for t, c in bars if day(t) == last_day]
    prior = [c for t, c in pairs(daily) if day(t) < last_day]
    if not prior: raise ValueError(f"{sym}: no daily close before {last_day}")
    return {"key": key, "name": name, "symbol": sym, "session_date": last_day.isoformat(),
            "prev_close": round(prior[-1], 2), "last": session[-1][1], "last_time": session[-1][0],
            "bars": [list(b) for b in session]}

def build():
    out = []
    for key, name, sym in INDEXES:
        out.append(shape(key, name, sym, get(sym, "5m", "5d"), get(sym, "1d", "1mo")))
        time.sleep(0.5)
    return {"generated_at": int(time.time()), "source": "Yahoo Finance chart API (delayed)",
            "indexes": out}

def selfcheck():
    # two ET days: 09-24 (daily close 100) then 09-25 session 101 -> 103, one null bar
    t0 = int(datetime(2026, 9, 25, 9, 30, tzinfo=ET).timestamp())
    d24 = int(datetime(2026, 9, 24, 16, 0, tzinfo=ET).timestamp())
    intr = {"timestamp": [d24, t0, t0 + 300, t0 + 600],
            "indicators": {"quote": [{"close": [99.0, 101.0, None, 103.0]}]}}
    daily = {"timestamp": [d24 - 86400, d24, t0], "indicators": {"quote": [{"close": [98.0, 100.0, 103.0]}]}}
    s = shape("sp500", "S&P 500", "^GSPC", intr, daily)
    assert s["session_date"] == "2026-09-25", s
    assert s["prev_close"] == 100.0, s          # the 09-24 close, not the 09-25 daily row
    assert s["bars"] == [[t0, 101.0], [t0 + 600, 103.0]], s   # prior day + null dropped
    assert s["last"] == 103.0 and s["last_time"] == t0 + 600
    print("✓ fetch selfcheck: 4 asserts")

if __name__ == "__main__":
    if "--selfcheck" in sys.argv: selfcheck(); sys.exit(0)
    out = pathlib.Path(sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else
                       pathlib.Path(__file__).parent / "data" / "market.json")
    data = build()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, separators=(",", ":")) + "\n")
    for i in data["indexes"]:
        print(f'{i["name"]:13} {i["session_date"]} last {i["last"]:>10} prev {i["prev_close"]:>10} '
              f'{(i["last"]/i["prev_close"]-1)*100:+.2f}%  {len(i["bars"])} bars')
