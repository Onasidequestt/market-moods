#!/usr/bin/env python3
"""fetch.py — pull the four US index series into data/market.json for the page.

Source: Yahoo Finance's public chart endpoint (no key). Index levels arrive delayed
(a 5-minute bar, fetched every 10 minutes by a best-effort scheduler: up to about 30 minutes behind).
Writes one file:
  data/market.json = {generated_at, source, indexes:[{key,name,symbol,session_date,
                      prev_close, last, last_time, bars:[[unix, close], ...]}]}
`bars` = every 5-minute close of the MOST RECENT session; `prev_close` = the official
daily close of the session before it. `sessions` = the same pair for each of the last five
trading days (oldest first), so replay can show a real down day as well as an up day.
The page decides live vs replay from last_time.

ponytail: Yahoo's endpoint is unofficial and can change or rate-limit. Ceiling: fine for a
prototype polled every 10 min by one GitHub Action. Upgrade path: a licensed feed
(Polygon/Finnhub/IEX) on the client's own host, where the key stays server-side.

Companies (--companies): the S&P 500's members ride inside its blob. Writes
  data/companies.json = {generated_at, source, index, companies:[{s,n,sec,cap}] (biggest first),
                         sessions:[{date, t:[unix...], m:[[bp...] | null per company]}]}
`t` = the S&P 500 index's own 5-minute bar times for that day (the page's clock), `m` = each
company's move from its previous official close, in basis points (0.01%), on that clock.

usage: fetch.py [--out data/market.json] | fetch.py --companies | fetch.py --selfcheck
"""
import html, http.cookiejar, json, pathlib, re, sys, time, urllib.request
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
    """Pure: each session's 5-min bars + the official close of the session before it."""
    bars = pairs(intraday)
    if not bars: raise ValueError(f"{sym}: no intraday bars")
    day = lambda t: datetime.fromtimestamp(t, ET).date()
    closes = pairs(daily)
    sessions = []
    for d in sorted({day(t) for t, _ in bars}):
        prior = [c for t, c in closes if day(t) < d]
        if not prior: continue                      # no close before it: cannot say how it moved
        sessions.append({"date": d.isoformat(), "prev_close": round(prior[-1], 2),
                         "bars": [[t, round(c, 2)] for t, c in bars if day(t) == d]})
    if not sessions: raise ValueError(f"{sym}: no daily close before {day(bars[-1][0])}")
    last = sessions[-1]
    return {"key": key, "name": name, "symbol": sym, "session_date": last["date"],
            "prev_close": last["prev_close"], "last": last["bars"][-1][1], "last_time": last["bars"][-1][0],
            "bars": last["bars"], "sessions": sessions}

def build():
    out = []
    for key, name, sym in INDEXES:
        out.append(shape(key, name, sym, get(sym, "5m", "5d"), get(sym, "1d", "1mo")))
        time.sleep(0.5)
    return {"generated_at": int(time.time()), "source": "Yahoo Finance chart API (delayed)",
            "indexes": out}

# ---------- companies inside the S&P 500 blob ----------
# ponytail: the member list is read from Wikipedia's "List of S&P 500 companies" table and sizes
# from Yahoo's quote endpoint (needs a session cookie + crumb, unofficial). Ceiling: fine for a
# prototype refreshed every 10 min. Upgrade path: the index provider's constituent file + the
# same licensed feed as the indexes, on the client's own host.
ROSTER_URL = "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies"
SPARK = "https://query1.finance.yahoo.com/v7/finance/spark?symbols={syms}&range={rng}&interval={iv}"
UA = {"User-Agent": "Mozilla/5.0 market-moods"}

def roster():
    """[(yahoo symbol, name, sector)] from the constituents table."""
    req = urllib.request.Request(ROSTER_URL, headers={"User-Agent": "market-moods/0.1 (prototype)"})
    page = urllib.request.urlopen(req, timeout=30).read().decode()
    tab = page[page.index('id="constituents"'):]; tab = tab[:tab.index("</table>")]
    out = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", tab, re.S)[1:]:
        c = [html.unescape(re.sub(r"<[^>]+>", "", x)).strip() for x in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
        if len(c) >= 3: out.append((c[0].replace(".", "-"), c[1], c[2]))
    if len(out) < 480: raise ValueError(f"roster has {len(out)} members, expected ~503")
    return out

def caps(syms):
    """{symbol: market value in $} from Yahoo's quote endpoint, 50 symbols per call."""
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    op.addheaders = list(UA.items())
    try: op.open("https://fc.yahoo.com", timeout=15)
    except Exception: pass                          # it 404s but still sets the cookie the crumb needs
    crumb = op.open("https://query1.finance.yahoo.com/v1/test/getcrumb", timeout=15).read().decode()
    out = {}
    for i in range(0, len(syms), 50):
        u = ("https://query1.finance.yahoo.com/v7/finance/quote?fields=marketCap&symbols="
             + ",".join(syms[i:i + 50]) + "&crumb=" + urllib.request.quote(crumb))
        for r in json.load(op.open(u, timeout=20))["quoteResponse"]["result"]:
            if r.get("marketCap"): out[r["symbol"]] = r["marketCap"]
        time.sleep(0.3)
    return out

def spark(syms, rng, iv):
    """{symbol: [(unix, close), ...]} — Yahoo's spark endpoint takes 20 symbols per call."""
    out = {}
    for i in range(0, len(syms), 20):
        u = SPARK.format(syms=",".join(syms[i:i + 20]), rng=rng, iv=iv)
        with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=20) as r:
            for x in json.load(r)["spark"]["result"]:
                res = (x.get("response") or [None])[0]
                if res: out[x["symbol"]] = pairs(res)
        time.sleep(0.3)
    return out

def shape_companies(members, caps_, sessions, intraday, daily):
    """Pure. members [(sym,name,sector)], caps_ {sym: $}, sessions = the S&P 500 index's
    [{date, bars}], intraday/daily {sym: [(unix, close)]}. Each company's move on each day is
    measured from ITS official close on the trading day before and laid on the index's own bar
    times; a bar the company lacks carries its last close forward. No bars that day, or no close
    ON the day before (Yahoo's daily series has gaps: a gap once turned MOS's -2.87% into -5.58%):
    null (drawn as nothing, never as flat, never from an older close)."""
    day = lambda t: datetime.fromtimestamp(t, ET).date().isoformat()
    ms = sorted([m for m in members if caps_.get(m[0])], key=lambda m: -caps_[m[0]])
    comps = [{"s": s, "n": n, "sec": sec, "cap": caps_[s]} for s, n, sec in ms]
    closes = {s: {day(t): c for t, c in daily.get(s, [])} for s, _, _ in ms}
    out = []
    for k, S in enumerate(sessions):
        grid = [t for t, _ in S["bars"]]
        if k: before = sessions[k - 1]["date"]
        else:   # the first day's "day before" = the latest earlier date most members have
            last = [max([d for d in cl if d < S["date"]], default=None) for cl in closes.values()]
            before = max(set(last) - {None}, key=lambda d: (last.count(d), d), default=None)   # tie: the later day
        row = []
        for s, _, _ in ms:
            prev = closes[s].get(before)
            own = {t: c for t, c in intraday.get(s, []) if day(t) == S["date"]}
            if prev is None or not own: row.append(None); continue
            lastc, bp = None, []
            first = own[min(own)]
            for t in grid:
                lastc = own.get(t, lastc if lastc is not None else first)
                bp.append(round((lastc / prev - 1) * 1e4))
            row.append(bp)
        out.append({"date": S["date"], "t": grid, "m": row})
    return {"index": "sp500", "companies": comps, "sessions": out}

def build_companies(market):
    sp = next(i for i in market["indexes"] if i["key"] == "sp500")
    members = roster()
    syms = [m[0] for m in members]
    c = caps(syms)
    data = shape_companies(members, c, sp["sessions"], spark(syms, "5d", "5m"), spark(syms, "1mo", "1d"))
    have = sum(1 for x in data["sessions"][-1]["m"] if x)
    if have < 450: raise ValueError(f"only {have} companies priced on {data['sessions'][-1]['date']}")
    data.update(generated_at=int(time.time()),
                source="Members: Wikipedia list of S&P 500 companies. Prices and market values: Yahoo Finance (delayed)")
    return data

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
    # every session carries the close of the day before it (09-24 <- 09-23's 98, 09-25 <- 09-24's 100)
    assert [(x["date"], x["prev_close"]) for x in s["sessions"]] == [("2026-09-24", 98.0), ("2026-09-25", 100.0)], s
    # a session with no daily close before it (09-22 here) is dropped, not guessed
    d22 = int(datetime(2026, 9, 22, 11, 0, tzinfo=ET).timestamp())
    s2 = shape("sp500", "S&P 500", "^GSPC", {"timestamp": [d22, t0], "indicators": {"quote": [{"close": [97.0, 101.0]}]}}, daily)
    assert [x["date"] for x in s2["sessions"]] == ["2026-09-25"], s2["sessions"]
    # companies: two members, one day on the index's clock [t0, t0+300, t0+600]
    sess = [{"date": "2026-09-25", "bars": [[t0, 1.0], [t0 + 300, 1.0], [t0 + 600, 1.0]]}]
    daily_c = {"AAA": [(d24, 200.0), (t0, 999.0)], "BBB": [(d24, 50.0)], "CCC": [(d24, 10.0)]}
    intr_c = {"AAA": [(d24, 190.0), (t0, 202.0), (t0 + 600, 198.0)],   # t0+300 missing: carried forward
              "BBB": [(t0, 50.0), (t0 + 300, 51.0)], "CCC": [(d24, 10.0)]}   # BBB's last bar missing: 51 carried
    c = shape_companies([("BBB", "Bee", "X"), ("AAA", "Ay", "Y"), ("CCC", "Sea", "Z"), ("DDD", "Dee", "Z")],
                        {"AAA": 3e12, "BBB": 1e11, "CCC": 5e10}, sess, intr_c, daily_c)
    assert [x["s"] for x in c["companies"]] == ["AAA", "BBB", "CCC"], c["companies"]   # biggest first, no cap = out
    m = c["sessions"][0]["m"]
    assert m[0] == [100, 100, -100], m[0]       # vs the 09-24 close 200 (not today's daily row), gap carried
    assert m[1] == [0, 200, 200], m[1]         # the LAST close carries, not the day's first
    assert m[2] is None, m[2]                   # no bars that day: nothing, not flat
    assert c["sessions"][0]["t"] == [t0, t0 + 300, t0 + 600]
    # a gap in the daily series: EEE has no 09-24 close, only 09-23's. It is left out, not measured
    # from the older close (the MOS bug); on day 2 its 09-25 close is present again and it is back.
    d23 = d24 - 86400
    sess2 = sess + [{"date": "2026-09-28", "bars": [[t0 + 3 * 86400, 1.0]]}]
    c2 = shape_companies([("AAA", "Ay", "Y"), ("EEE", "Ee", "Y")], {"AAA": 2e12, "EEE": 1e9}, sess2,
                         {"AAA": intr_c["AAA"] + [(t0 + 3 * 86400, 200.0)], "EEE": [(t0, 30.0), (t0 + 3 * 86400, 33.0)]},
                         {"AAA": [(d24, 200.0), (t0, 199.0)], "EEE": [(d23, 20.0), (t0, 30.0)]})
    assert c2["sessions"][0]["m"][1] is None, c2["sessions"][0]["m"]
    assert c2["sessions"][1]["m"] == [[50], [1000]], c2["sessions"][1]["m"]   # vs 09-25 closes 199 and 30
    print("✓ fetch selfcheck: 13 asserts")

if __name__ == "__main__":
    if "--selfcheck" in sys.argv: selfcheck(); sys.exit(0)
    if "--companies" in sys.argv:
        here = pathlib.Path(__file__).parent / "data"
        data = build_companies(json.loads((here / "market.json").read_text()))
        (here / "companies.json").write_text(json.dumps(data, separators=(",", ":")) + "\n")
        last = data["sessions"][-1]; up = sum(1 for x in last["m"] if x and x[-1] > 0)
        print(f'companies: {len(data["companies"])} members, {len(data["sessions"])} days, '
              f'{last["date"]}: {up} up of {sum(1 for x in last["m"] if x)} priced')
        sys.exit(0)
    out = pathlib.Path(sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else
                       pathlib.Path(__file__).parent / "data" / "market.json")
    data = build()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, separators=(",", ":")) + "\n")
    for i in data["indexes"]:
        print(f'{i["name"]:13} {i["session_date"]} last {i["last"]:>10} prev {i["prev_close"]:>10} '
              f'{(i["last"]/i["prev_close"]-1)*100:+.2f}%  {len(i["bars"])} bars')
