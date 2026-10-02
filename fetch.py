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
import csv, html, http.cookiejar, io, json, pathlib, re, ssl, sys, time, urllib.error, urllib.request
from datetime import datetime, timedelta, timezone
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

def _volumes(res):
    """{unix: volume} for the same bars pairs() keeps (a close present) — volume heartbeat reuses
    the SAME chart response already fetched for prices (rule 4: no new source, no new call)."""
    ts, cl = res.get("timestamp") or [], res["indicators"]["quote"][0]["close"]
    vol = res["indicators"]["quote"][0].get("volume") or [None] * len(ts)
    return {t: v for t, c, v in zip(ts, cl, vol) if c is not None and v is not None}

def shape(key, name, sym, intraday, daily):
    """Pure: each session's 5-min bars + the official close of the session before it.
    Each bar is [unix, close, volume|null] — volume rides along with the same bar it was already
    fetched with; null (not zero, not carried forward) when Yahoo didn't report one, so a missing
    reading is never drawn as a real, quiet moment (rule 6)."""
    bars = pairs(intraday)
    if not bars: raise ValueError(f"{sym}: no intraday bars")
    vols = _volumes(intraday)
    day = lambda t: datetime.fromtimestamp(t, ET).date()
    closes = pairs(daily)
    sessions = []
    for d in sorted({day(t) for t, _ in bars}):
        prior = [c for t, c in closes if day(t) < d]
        if not prior: continue                      # no close before it: cannot say how it moved
        sessions.append({"date": d.isoformat(), "prev_close": round(prior[-1], 2),
                         "bars": [[t, round(c, 2), vols.get(t)] for t, c in bars if day(t) == d]})
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
    # the fear gauge: ^VIX on the same Yahoo source, shaped by the SAME shape() function as the
    # four indexes (rule 1: reuse, not a parallel parser) — kept as its own top-level field, not a
    # fifth index, so it never touches the "four indexes" shape the rest of the page/checks assume.
    vix = None
    try:
        vix = shape("vix", "VIX", "^VIX", get("^VIX", "5m", "5d"), get("^VIX", "1d", "1mo"))
    except Exception as e:
        print(f"vix fetch failed (non-fatal, the lamp just runs without a fear gauge): {e}", file=sys.stderr)
    out_d = {"generated_at": int(time.time()), "source": "Yahoo Finance chart API (delayed)",
             "indexes": out}
    if vix is not None: out_d["vix"] = vix
    return out_d

# ---------- companies inside each index blob ----------
# ponytail: member lists come from free, unofficial sources (Wikipedia / nasdaq.com screener /
# an iShares ETF's holdings CSV) and sizes from Yahoo's quote endpoint (session cookie + crumb,
# also unofficial). Ceiling: fine for a prototype refreshed every 10 min. Upgrade path: each
# index provider's own constituent file + a licensed feed, on the client's own host.
ROSTER_URL = "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies"
DOW_URL = "https://en.wikipedia.org/wiki/List_of_Dow_Jones_Industrial_Average_companies"
NASDAQ_URL = "https://api.nasdaq.com/api/screener/stocks?tableonly=true&limit=8000&exchange=nasdaq&download=true"
# ponytail: IWM (iShares Russell 2000 ETF) holdings are a widely-used FREE stand-in for the Russell
# 2000's own (paid, FTSE Russell) member list. Ceiling: an ETF's holdings can lag/differ slightly
# from the index (cash, sampling, rebalancing lag). Upgrade path: FTSE Russell's licensed list.
RUSSELL_URL = ("https://www.ishares.com/us/products/239710/ishares-russell-2000-etf/"
               "1467271812596.ajax?fileType=csv&fileName=IWM_holdings&dataType=fund")
SPARK = "https://query1.finance.yahoo.com/v7/finance/spark?symbols={syms}&range={rng}&interval={iv}"
UA = {"User-Agent": "Mozilla/5.0 market-moods"}

# how many companies each index's inside view can show, and where its roster comes from
INDEX_CAP = {"dow": 30, "sp500": 500, "nasdaq": 500, "russell": 500}

# sector labels are not uniform across sources (Wikipedia's S&P/Dow tables use GICS sector names;
# nasdaq.com's screener uses its own shorter labels) — normalised ONCE, here, for every roster
# (rule 1: one shared function, not a per-index patch), so "sectors as organs" groups the same
# organ regardless of which source a company came from.
SECTOR_ALIAS = {"Technology": "Information Technology", "Finance": "Financials",
                "Basic Materials": "Materials", "Telecommunications": "Communication Services",
                "Miscellaneous": "Other", "": "Other"}
def norm_sector(s):
    return SECTOR_ALIAS.get(s, s)

def _wiki_table(url, anchor):
    req = urllib.request.Request(url, headers={"User-Agent": "market-moods/0.1 (prototype)"})
    page = urllib.request.urlopen(req, timeout=30).read().decode()
    tab = page[page.index(anchor):]; tab = tab[:tab.index("</table>")]
    out = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", tab, re.S)[1:]:
        c = [html.unescape(re.sub(r"<[^>]+>", "", x)).strip() for x in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.S)]
        if c: out.append(c)
    return out

def roster():
    """([(yahoo symbol, name, sector)], precap=None) — the S&P 500 constituents table."""
    out = []
    for c in _wiki_table(ROSTER_URL, 'id="constituents"'):
        if len(c) >= 3: out.append((c[0].replace(".", "-"), c[1], norm_sector(c[2])))
    if len(out) < 480: raise ValueError(f"sp500 roster has {len(out)} members, expected ~503")
    return out, None

def roster_dow():
    """([(symbol, name, sector)], None) — all 30 Dow members: "List of Dow Jones Industrial
    Average companies" constituents table (Company, Exchange, Symbol, Sector, ...)."""
    out = []
    for c in _wiki_table(DOW_URL, 'id="constituents"'):
        if len(c) >= 4: out.append((c[2].replace(".", "-"), c[0], norm_sector(c[3])))
    if len(out) != 30: raise ValueError(f"dow roster has {len(out)} members, expected 30")
    return out, None

def roster_nasdaq():
    """([(symbol, name, sector)], precap) — nasdaq.com screener (equities only; ETFs/units/
    warrants/test issues filtered). precap comes free in the same response: no extra HTTP call."""
    req = urllib.request.Request(NASDAQ_URL, headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36",
        "Accept": "application/json"})
    rows = json.load(urllib.request.urlopen(req, timeout=30))["data"]["rows"]
    out, precap = [], {}
    for r in rows:
        sym, name = r.get("symbol", ""), r.get("name", "")
        if not sym or not name: continue
        if re.search(r"\b(ETF|Fund|Trust|Warrants?|Units?|Notes?)\b", name, re.I): continue
        if "^" in sym or "." in sym or re.search(r"Test Issue", name, re.I): continue
        out.append((sym, name, norm_sector(r.get("sector") or "")))
        try: cap = float(str(r.get("marketCap") or 0).replace(",", ""))
        except ValueError: cap = 0
        if cap: precap[sym] = cap
    if len(out) < 2000: raise ValueError(f"nasdaq roster has {len(out)} members, expected 2000+")
    return out, precap

def roster_russell():
    """([(symbol, name, sector)], precap) — IWM (iShares Russell 2000 ETF) holdings CSV, equity
    rows only. precap = each holding's Market Value in the fund: a proxy for company size (the
    fund is cap-weighted), not the company's real market cap. Used only to pick the top 500
    before spending HTTP calls on prices; the page's "bigger = bigger company" size still uses
    the real market cap fetched afterward via caps()."""
    req = urllib.request.Request(RUSSELL_URL, headers=UA)
    text = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
    lines = text.splitlines()
    hdr = next((i for i, l in enumerate(lines) if l.startswith("Ticker,")), None)
    if hdr is None: raise ValueError("IWM csv: no header row found")
    import csv, io
    rows = list(csv.reader(io.StringIO("\n".join(lines[hdr:]))))
    cols = rows[0]
    i_t, i_n, i_s, i_a = cols.index("Ticker"), cols.index("Name"), cols.index("Sector"), cols.index("Asset Class")
    i_v = cols.index("Market Value") if "Market Value" in cols else None
    out, precap = [], {}
    for r in rows[1:]:
        if len(r) <= max(i_t, i_n, i_s, i_a): continue
        if r[i_a].strip() != "Equity": continue
        sym = r[i_t].strip()
        if not sym or not re.fullmatch(r"[A-Z.\-]{1,6}", sym): continue
        sym = sym.replace(".", "-")
        out.append((sym, r[i_n].strip(), norm_sector(r[i_s].strip())))
        if i_v is not None:
            try: v = float(r[i_v].replace(",", "").replace("$", ""))
            except ValueError: v = 0
            if v: precap[sym] = v
    if len(out) < 1500: raise ValueError(f"russell (IWM) roster has {len(out)} members, expected 1500+")
    return out, precap

ROSTERS = {"dow": roster_dow, "sp500": roster, "nasdaq": roster_nasdaq, "russell": roster_russell}

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
        for r in _retry(lambda u=u: json.load(op.open(u, timeout=20))["quoteResponse"]["result"]):
            if r.get("marketCap"): out[r["symbol"]] = r["marketCap"]
        time.sleep(0.4)
    return out

def _retry(fn, tries=3, delay=1.5):
    """A flaky unofficial endpoint gets a few retries with backoff before we give up the batch —
    a lot cheaper than failing the whole --companies run over one dropped connection."""
    for attempt in range(tries):
        try: return fn()
        except Exception:
            if attempt == tries - 1: raise
            time.sleep(delay * (attempt + 1))

def spark(syms, rng, iv):
    """{symbol: [(unix, close), ...]} — Yahoo's spark endpoint takes 20 symbols per call."""
    out = {}
    for i in range(0, len(syms), 20):
        u = SPARK.format(syms=",".join(syms[i:i + 20]), rng=rng, iv=iv)
        def call(u=u):
            with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=20) as r:
                return json.load(r)["spark"]["result"]
        for x in _retry(call):
            res = (x.get("response") or [None])[0]
            if res: out[x["symbol"]] = pairs(res)
        time.sleep(0.5)
    return out

def shape_companies(members, caps_, sessions, intraday, daily, index="sp500"):
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
        grid = [b[0] for b in S["bars"]]   # a bar is [unix, close, volume|null] (volume added 09-30; a 2-tuple unpack here froze every companies file)
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
    return {"index": index, "companies": comps, "sessions": out}

# where each index's member list comes from, in the words shown on the page (rule 6: honest sourcing)
SOURCE_NOTE = {
    "dow": "Members: Wikipedia's Dow Jones Industrial Average components table (all 30). "
           "Prices and market values: Yahoo Finance (delayed)",
    "sp500": "Members: Wikipedia's list of S&P 500 companies. Prices and market values: Yahoo Finance (delayed)",
    "nasdaq": "Members: nasdaq.com's stock screener (Nasdaq-listed equities, top 500 by market value). "
              "Prices and market values: Yahoo Finance (delayed)",
    "russell": "Members: the iShares Russell 2000 ETF (IWM)'s holdings, a free stand-in for FTSE "
               "Russell's own (paid) list, top 500 by fund position. Prices and market values: Yahoo Finance (delayed)",
}
# rough floor for "did pricing actually work" per index, scaled off INDEX_CAP (rule 2: a check that can verify)
MIN_PRICED = {"dow": 27, "sp500": 450, "nasdaq": 400, "russell": 400}

def market_open(now=None):
    """Pure: is NYSE in its regular session (Mon-Fri 9:30-16:25 ET; the grace after the bell lets one last round catch the closing bars)?
    ponytail: holidays are not modelled - on one the loop just refetches an unchanged file and commits nothing."""
    n = (now or datetime.now(ET)).astimezone(ET)
    return n.weekday() < 5 and (9, 30) <= (n.hour, n.minute) <= (16, 25)

def econ_open(now=None):
    """Pure: do the economy's futures trade (CME: Sun 18:00 ET to Fri 17:00 ET)? The daily 1-hour break is ignored."""
    n = (now or datetime.now(ET)).astimezone(ET); w, hm = n.weekday(), (n.hour, n.minute)   # Mon=0 .. Sun=6
    return not (w == 5 or (w == 4 and hm >= (17, 0)) or (w == 6 and hm < (18, 0)))

def build_companies(market, index="sp500"):
    ix = next(i for i in market["indexes"] if i["key"] == index)
    members, precap = ROSTERS[index]()
    cap_n = INDEX_CAP[index]
    if precap is not None and len(members) > cap_n:
        # rank by the free precap first so we only spend Yahoo calls (caps + spark) on the ones we'll show
        members = sorted(members, key=lambda m: -precap.get(m[0], 0))[:cap_n]
    syms = [m[0] for m in members]
    c = caps(syms)
    data = shape_companies(members, c, ix["sessions"], spark(syms, "5d", "5m"), spark(syms, "1mo", "1d"), index)
    have = sum(1 for x in data["sessions"][-1]["m"] if x)
    if have < MIN_PRICED[index]:
        raise ValueError(f"{index}: only {have} companies priced on {data['sessions'][-1]['date']}")
    data.update(generated_at=int(time.time()), source=SOURCE_NOTE[index])
    return data

# ---------- economy: grouped blobs for commodities, rates and the slow macro numbers ----------
# One blob per group, its members inside (same shape as an index and its companies). Two sources,
# both keyless: Yahoo Finance futures/yields (the same chart endpoint as the indexes, delayed) and
# FRED's public CSV download (the series' own release rhythm: daily / weekly / monthly). A member's
# raw prev/last are stored; the page turns them into a move with mood.js's econMove (one rule).
# ponytail: FRED's CSV is the free keyless door, Yahoo's futures are unofficial and delayed ~10 min.
# Ceiling: fine for a prototype; monthly numbers can only be as fresh as their release. Upgrade path:
# FRED's keyed API (vintages, release calendar) and a licensed commodities feed on the client's host.
FRED = "https://fred.stlouisfed.org/graph/fredgraph.csv?id={id}&cosd={since}"   # cosd: the whole history is slow (5 s); 3 years is instant
# member: (key, name, source, symbol, kind, unit, freq). kind = how a move is measured (mood.js econMove):
# pct = percent change of the level, bp = change of a rate in basis points, pt = change in points
# of a rate (unemployment), jobs = change in thousands of jobs.
ECON = [
    ("energy", "Energy", "Energy", [
        ("brent", "Brent crude", "y", "BZ=F", "pct", "$ / barrel", "5min"),
        ("wti", "WTI crude", "y", "CL=F", "pct", "$ / barrel", "5min"),
        ("natgas", "Natural gas", "y", "NG=F", "pct", "$ / MMBtu", "5min"),
        ("gasoline", "Gasoline", "y", "RB=F", "pct", "$ / gallon", "5min"),
        ("heatoil", "Heating oil", "y", "HO=F", "pct", "$ / gallon", "5min")]),
    ("metals", "Metals", "Metals", [
        ("gold", "Gold", "y", "GC=F", "pct", "$ / oz", "5min"),
        ("silver", "Silver", "y", "SI=F", "pct", "$ / oz", "5min"),
        ("copper", "Copper", "y", "HG=F", "pct", "$ / lb", "5min"),
        ("platinum", "Platinum", "y", "PL=F", "pct", "$ / oz", "5min"),
        ("palladium", "Palladium", "y", "PA=F", "pct", "$ / oz", "5min"),
        ("aluminium", "Aluminium", "y", "ALI=F", "pct", "$ / tonne", "5min"),
        ("steel", "Hot-rolled steel", "y", "HRC=F", "pct", "$ / short ton", "5min")]),
    ("farm", "Farm goods", "Farm", [
        ("corn", "Corn", "y", "ZC=F", "pct", "cents / bushel", "5min"),
        ("soy", "Soybeans", "y", "ZS=F", "pct", "cents / bushel", "5min"),
        ("wheat", "Wheat", "y", "ZW=F", "pct", "cents / bushel", "5min"),
        ("cotton", "Cotton", "y", "CT=F", "pct", "cents / lb", "5min"),
        ("coffee", "Coffee", "y", "KC=F", "pct", "cents / lb", "5min"),
        ("sugar", "Sugar", "y", "SB=F", "pct", "cents / lb", "5min"),
        ("cocoa", "Cocoa", "y", "CC=F", "pct", "$ / tonne", "5min"),
        ("oats", "Oats", "y", "ZO=F", "pct", "cents / bushel", "5min"),
        ("rice", "Rough rice", "y", "ZR=F", "pct", "$ / hundredweight", "5min"),
        ("oj", "Orange juice", "y", "OJ=F", "pct", "cents / lb", "5min"),
        ("cattle", "Live cattle", "y", "LE=F", "pct", "cents / lb", "5min"),
        ("feeder", "Feeder cattle", "y", "GF=F", "pct", "cents / lb", "5min"),
        ("hogs", "Lean hogs", "y", "HE=F", "pct", "cents / lb", "5min"),
        ("lumber", "Lumber", "y", "LBR=F", "pct", "$ / 1,000 board ft", "5min")]),
    ("rates", "Rates & the dollar", "Rates", [
        ("t3m", "3-month bill", "y", "^IRX", "bp", "% yield", "5min"),
        ("t5y", "5-year note", "y", "^FVX", "bp", "% yield", "5min"),
        ("t10y", "10-year note", "y", "^TNX", "bp", "% yield", "5min"),
        ("t30y", "30-year bond", "y", "^TYX", "bp", "% yield", "5min"),
        ("dollar", "US dollar index", "y", "DX-Y.NYB", "pct", "index vs 6 currencies", "5min")]),
    ("macro", "The economy", "Economy", [
        ("mortgage", "30-year mortgage rate", "f", "MORTGAGE30US", "bp", "% rate", "weekly"),
        ("cpi", "Consumer prices (CPI)", "f", "CPIAUCSL", "pct", "index", "monthly"),
        ("unemp", "Unemployment rate", "f", "UNRATE", "pt", "% of workers", "monthly"),
        ("payrolls", "Jobs on payrolls", "f", "PAYEMS", "jobs", "thousand jobs", "monthly"),
        ("claims", "Jobless claims", "f", "ICSA", "pct", "claims / week", "weekly"),
        ("sentiment", "Consumer sentiment", "f", "UMCSENT", "pct", "index", "monthly"),
        ("retail", "Retail sales", "f", "RSAFS", "pct", "$ million / month", "monthly"),
        ("spending", "Consumer spending (PCE)", "f", "PCE", "pct", "$ billion / year", "monthly"),
        ("homes", "Home values (Case-Shiller)", "f", "CSUSHPINSA", "pct", "index", "monthly")]),
    ("debt", "Debt & money", "Debt", [
        ("credit", "Consumer credit", "f", "TOTALSL", "pct", "$ million owed", "monthly"),
        ("cards", "Card & revolving debt", "f", "REVOLSL", "pct", "$ million owed", "monthly"),
        ("fedDebt", "Federal debt", "f", "GFDEBTN", "pct", "$ million owed", "quarterly"),
        ("m1", "Money supply (M1)", "f", "M1SL", "pct", "$ billion", "monthly"),
        ("worldDebt", "World government debt", "i", "GGXWDG_NGDP/WEOWORLD", "gdp", "% of world GDP (IMF estimate)", "yearly")]),
    ("shipping", "Shipping & trade", "Shipping", [
        ("trade", "Trade balance", "f", "BOPGSTB", "bn", "$ million / month", "monthly"),
        ("cassShip", "Freight shipments (Cass)", "f", "FRGSHPUSM649NCIS", "pct", "index", "monthly"),
        ("cassSpend", "Freight spending (Cass)", "f", "FRGEXPUSM649NCIS", "pct", "index", "monthly"),
        ("trucking", "Trucking prices (PPI)", "f", "PCU484121484121", "pct", "index", "monthly"),
        ("railCars", "Rail freight carloads", "f", "RAILFRTCARLOADSD11", "pct", "carloads / month", "monthly"),
        ("railBox", "Rail intermodal (containers on trains)", "f", "RAILFRTINTERMODAL", "pct", "units / month", "monthly"),
        ("tsi", "Freight services index (all modes)", "f", "TSIFRGHT", "pct", "index", "monthly"),
        ("truckTons", "Truck tonnage", "f", "TRUCKD11", "pct", "index", "monthly"),
        ("imports", "Import prices", "f", "IR", "pct", "index", "monthly"),
        ("exports", "Export prices", "f", "IQ", "pct", "index", "monthly"),
        ("tradeCH", "US trade balance with China", "t", "EXPCH:IMPCH", "bn", "$ million / month", "monthly"),
        ("tradeCA", "US trade balance with Canada", "t", "EXPCA:IMPCA", "bn", "$ million / month", "monthly"),
        ("tradeMX", "US trade balance with Mexico", "t", "EXPMX:IMPMX", "bn", "$ million / month", "monthly"),
        ("tradeJP", "US trade balance with Japan", "t", "EXPJP:IMPJP", "bn", "$ million / month", "monthly"),
        ("tradeKR", "US trade balance with South Korea", "t", "EXPKR:IMPKR", "bn", "$ million / month", "monthly"),
        ("tradeUK", "US trade balance with United Kingdom", "t", "EXPUK:IMPUK", "bn", "$ million / month", "monthly"),
        ("tradeGE", "US trade balance with Germany", "t", "EXPGE:IMPGE", "bn", "$ million / month", "monthly"),
        ("tradeFR", "US trade balance with France", "t", "EXPFR:IMPFR", "bn", "$ million / month", "monthly")]),
    ("cbanks", "Central banks", "Central banks", [
        ("fedAssets", "Fed holdings (balance sheet)", "f", "WALCL", "pct", "$ million held", "weekly"),
        ("ecbAssets", "ECB holdings (balance sheet)", "f", "ECBASSETSW", "pct", "\u20ac million held", "weekly"),
        ("bojAssets", "Bank of Japan holdings (balance sheet)", "f", "JPNASSETS", "pct", "\u00a5 100 million held", "monthly"),
        ("boeAssets", "Bank of England holdings (balance sheet)", "m", "bis:GB", "pct", "\u00a3 billion held", "quarterly"),
        ("pbocAssets", "People's Bank of China holdings (balance sheet)", "m", "bis:CN", "pct", "\u00a5 billion held", "quarterly"),
        ("snbAssets", "Swiss National Bank holdings (balance sheet)", "m", "bis:CH", "pct", "CHF billion held", "quarterly"),
        ("goldUSA", "Gold held: United States", "m", "irfcl:USA", "pct", "tonnes", "monthly"),
        ("goldDEU", "Gold held: Germany", "m", "irfcl:DEU", "pct", "tonnes", "monthly"),
        ("goldITA", "Gold held: Italy", "m", "irfcl:ITA", "pct", "tonnes", "monthly"),
        ("goldFRA", "Gold held: France", "m", "irfcl:FRA", "pct", "tonnes", "monthly"),
        ("goldCHN", "Gold held: China", "m", "irfcl:CHN", "pct", "tonnes", "monthly"),
        ("goldIND", "Gold held: India", "m", "irfcl:IND", "pct", "tonnes", "monthly"),
        ("goldPOL", "Gold held: Poland", "m", "irfcl:POL", "pct", "tonnes", "monthly"),
        ("goldTUR", "Gold held: Turkey", "m", "irfcl:TUR", "pct", "tonnes", "monthly"),
        ("fxReserves", "World FX reserves (all central banks)", "m", "cofer:CI_T:NV_USD", "pct", "$ trillion", "quarterly"),
        ("usdShare", "US dollar share of FX reserves", "m", "cofer:CI_USD:SHRO_PT", "pct", "% of allocated reserves", "quarterly")]),
]
# things Clark asked for that no free keyless source carries: listed on the page, never faked
ECON_SHORT = {"mortgage": "Mortgage", "cpi": "CPI", "unemp": "Unemp.", "payrolls": "Payrolls", "claims": "Claims",
              "sentiment": "Sentiment", "retail": "Retail", "spending": "Spending", "homes": "Homes", "dollar": "Dollar", "t3m": "3-month", "t5y": "5-year",
              "t10y": "10-year", "t30y": "30-year", "natgas": "Nat. gas", "heatoil": "Heating oil", "steel": "Steel",
              "aluminium": "Aluminium", "brent": "Brent", "wti": "WTI", "credit": "Credit", "cards": "Cards", "fedDebt": "Fed. debt",
              "m1": "M1", "railCars": "Rail cars", "railBox": "Intermodal", "tsi": "Freight idx", "truckTons": "Tonnage", "imports": "Imports $", "exports": "Exports $", "tradeCH": "China", "tradeCA": "Canada", "tradeMX": "Mexico", "tradeJP": "Japan", "tradeKR": "S. Korea", "tradeUK": "UK", "tradeGE": "Germany", "tradeFR": "France", "goldUSA": "US", "goldDEU": "Germany", "goldITA": "Italy", "goldFRA": "France", "goldCHN": "China", "goldIND": "India", "goldPOL": "Poland", "goldTUR": "Turkey", "boeAssets": "BoE", "pbocAssets": "PBoC", "snbAssets": "SNB", "fxReserves": "FX reserves", "usdShare": "USD share",  "fedAssets": "Fed", "ecbAssets": "ECB", "bojAssets": "BoJ", "worldDebt": "World debt", "trade": "Trade", "cassShip": "Shipments", "cassSpend": "Freight $",
              "trucking": "Trucking", "feeder": "Feeder", "oj": "OJ", "cattle": "Cattle", "rice": "Rice", "hogs": "Hogs"}     # a blob's label; the full name rides in the tooltip
ECON_MISSING = [("metals", "Cobalt", "no free public price series (LME and Fastmarkets are paid; FRED has none)"),
                ("energy", "Propane", "Yahoo lists Mont Belvieu propane (B0=F) but it printed once in 5 days: too thin for a move"),
                ("energy", "Ethanol", "Yahoo's ethanol future (EH=F) returns no prices; no other free keyless feed"),
                ("shipping", "Baltic Dry Index", "licensed by the Baltic Exchange; no free feed (Cass freight indexes stand in)"),
                ("shipping", "UPS / FedEx rates", "published as rate cards, not a data feed"),
                ("shipping", "Trade between other country pairs", "only pairs with the US come free (FRED, from the Census); other pairs need a Census/UN key or are over a year old"),
                ("cbanks", "Reserves reported by Russia and a few others", "not every central bank reports every month to the IMF: Russia's last gold report is months old, so it is left out rather than shown stale"),
                ("cbanks", "Central-bank crypto holdings", "no central bank reports holding any; the only figures are one-off third-party estimates of government wallets (CoinGecko lists China ~190,000 BTC, Bhutan ~10,800) with no history to measure a move from")]

def parse_fred(text):
    """[(date 'YYYY-MM-DD', value)] from a fredgraph.csv; FRED's '.' (no reading) rows are dropped."""
    rows = []
    for ln in text.strip().splitlines()[1:]:
        d, _, v = ln.partition(",")
        try: rows.append((d.strip(), float(v)))
        except ValueError: pass
    return rows

def econ_yahoo(spec, daily, intraday):
    """Pure. A market-traded member: newest price vs the close before it. The basis is the DAILY
    series (last bar vs the one before), not a split by ET calendar day: futures trade nearly around
    the clock, so 'today' has no clean edge. Falls back to the last two daily closes when there are
    no intraday bars (thin markets), and says so in `freq`."""
    key, name, _, sym, kind, unit, _f = spec
    d = pairs(daily)
    if len(d) < 2: raise ValueError(f"{sym}: fewer than two daily closes")
    i = pairs(intraday) if intraday else []
    live = bool(i) and i[-1][0] >= d[-1][0]
    lt, last = i[-1] if live else d[-1]
    prev = d[-2][1]
    yc = ((intraday or {}).get("meta") or {}).get("previousClose")
    if yc:
        # Yahoo's own previous settle for the CURRENT front contract. The daily series splices contracts at each
        # roll (09-30: Brent's daily row said 102.59 while that day traded 96-99, reading -6.8% for a -0.3% day),
        # so it is the basis only when this is missing.
        prev = yc
    elif len(d) >= 4 and d[-4][1] == d[-3][1] == d[-2][1]:
        # a thin contract's daily "close" can freeze on a stale settlement (HRC=F sat on 1237 for a week while
        # it traded 1300+ and read +7%); three identical closes in a row = frozen, so the basis becomes the
        # last real print before today's daily bar, and with no such print there is no honest move at all
        before = [c for t, c in i if t < d[-1][0]]
        if not before: raise ValueError(f"{sym}: daily closes frozen at {prev} and no earlier print")
        prev = before[-1]
    return {"key": key, "name": name, "sym": sym, "kind": kind, "unit": unit, "freq": "5min" if live else "daily",
            "src": "Yahoo Finance", "prev": round(prev, 4), "last": round(last, 4), "last_time": lt,
            "asof": datetime.fromtimestamp(lt, ET).date().isoformat(),
            "bars": [[t, round(c, 4)] for t, c in i[-24:]] if live else []}

def econ_fred(spec, rows, src=None):
    """Pure. A slow member: its latest reading vs the one before, dated by the reading's own date."""
    key, name, _, sid, kind, unit, freq = spec
    if len(rows) < 2: raise ValueError(f"{sid}: fewer than two readings")
    (pd_, prev), (ld, last) = rows[-2], rows[-1]
    m = {"key": key, "name": name, "sym": sid, "kind": kind, "unit": unit, "freq": freq,
         "src": src or (f"IMF World Economic Outlook ({sid}, estimate)" if spec[2] == "i" else f"FRED ({sid})"), "prev": prev, "last": last, "asof": ld, "prev_asof": pd_}
    if freq == "monthly" and kind == "pct" and len(rows) > 12:
        m["yoy"] = round((last / rows[-13][1] - 1) * 100, 2)      # against the same month a year before
    return m

def get_fred(sid):
    since = (datetime.now(timezone.utc) - timedelta(days=3 * 365)).date().isoformat()
    def call():
        req = urllib.request.Request(FRED.format(id=sid, since=since))   # no custom User-Agent: FRED drops browser-like and made-up ones, and answers urllib's own
        with urllib.request.urlopen(req, timeout=25) as r:
            return parse_fred(r.read().decode())
    return _retry(call)

# IMF DataMapper (keyless JSON, World Economic Outlook): one value per year, and the WEO carries
# projections years ahead, so only years before this one count as readings (2025 vs 2024 in 2026).
# ponytail: yearly and an IMF estimate; upgrade = the IMF's own quarterly debt database, which needs SDMX.
IMF = "https://www.imf.org/external/datamapper/api/v1/{ind}/{area}"
def parse_imf(d, ind, area, year):
    """Pure. [(YYYY-01-01, value)] for past years only."""
    vals = d["values"][ind][area]
    return [(f"{y}-01-01", float(v)) for y, v in sorted(vals.items()) if int(y) < year and v is not None]

def get_imf(spec):
    ind, area = spec.split("/")
    def call():
        with urllib.request.urlopen(IMF.format(ind=ind, area=area), timeout=30) as r:
            return parse_imf(json.load(r), ind, area, datetime.now(timezone.utc).year)
    return _retry(call)


# --- IMF International Reserves (IRFCL: gold), IMF COFER (reserve currencies), BIS central-bank assets, US bilateral trade ---
# All free and keyless. api.imf.org sends an INCOMPLETE certificate chain (curl exit 60, urllib CERTIFICATE_VERIFY_FAILED on
# a Mac; untested on a runner): on that one error we retry unverified. ponytail: this is public read-only statistics, so a
# swapped file is the only risk; every value is range-checked (check.js) and the page names the source. Upgrade: pin the
# IMF intermediate cert, or fetch via DBnomics' mirror (a year behind).
_csv_cache = {}
def get_csv(url, accept="text/csv"):
    if url in _csv_cache: return _csv_cache[url]
    def call():
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 market-moods", "Accept": accept})
        try: r = urllib.request.urlopen(req, timeout=60)
        except urllib.error.URLError as e:
            if not isinstance(e.reason, ssl.SSLCertVerificationError): raise
            r = urllib.request.urlopen(req, timeout=60, context=ssl._create_unverified_context())
        with r: return list(csv.DictReader(io.StringIO(r.read().decode("utf-8-sig"))))
    _csv_cache[url] = _retry(call)
    return _csv_cache[url]

OZ_PER_TONNE = 32150.7466
IMF_SDMX = "https://api.imf.org/external/sdmx/2.1/data/"
SDMX_CSV = "application/vnd.sdmx.data+csv;version=1.0.0"
GOLD_COUNTRIES = "+".join(sp[3].split(":")[1] for g in ECON for sp in g[3] if sp[3].startswith("irfcl:"))
def _per(p):
    """'2026-M08' -> '2026-08-01', '2026-Q2' -> '2026-04-01' (first day of the period)."""
    y, _, r = p.partition("-")
    return f"{y}-{int(r[1:]):02d}-01" if r[0] == "M" else f"{y}-{3 * (int(r[1:]) - 1) + 1:02d}-01"

def parse_irfcl_gold(rows, ctry):
    """Pure. [(date, tonnes)] of one country's official gold (IRFCL, fine troy ounces / 32150.75). Monetary authorities
    + central government (S1XS1311) when the country reports it, else S1X; duplicates dropped."""
    mine = [r for r in rows if r["COUNTRY"] == ctry and r["OBS_VALUE"] not in ("", None)]
    for sec in ("S1XS1311", "S1X"):
        pick = {r["TIME_PERIOD"]: float(r["OBS_VALUE"]) for r in mine if r["SECTOR"] == sec}
        if pick: break
    else: pick = {}
    return [(_per(p), v / OZ_PER_TONNE) for p, v in sorted(pick.items())]

def parse_cofer(rows, cur, tr):
    """Pure. [(date, value)] for the world allocated reserves in one currency: tr SHRO_PT = share in %, NV_USD = $ trillion."""
    div = 1e12 if tr == "NV_USD" else 1
    pick = {r["TIME_PERIOD"]: float(r["OBS_VALUE"]) / div for r in rows
            if r["COUNTRY"] == "G001" and r["INDICATOR"] == "AFXRA" and r["FXR_CURRENCY"] == cur and r["TYPE_OF_TRANSFORMATION"] == tr and r["OBS_VALUE"]}
    return [(_per(p), v) for p, v in sorted(pick.items())]

def parse_bis_assets(rows, area):
    """Pure. [(date, billions of the bank's own currency)] - total assets, own currency (not USD: the dollar would
    move the number on a day the bank did nothing). The file repeats rows; one per quarter."""
    pick = {r["TIME_PERIOD"]: float(r["OBS_VALUE"]) * 10 ** (int(r["UNIT_MULT"]) - 9) for r in rows
            if r["REF_AREA"] == area and r["UNIT_MEASURE"] == "XDC" and r["OBS_VALUE"]}
    return [(_per(p), v) for p, v in sorted(pick.items())]

def get_sdmx(code):
    """(rows, src) for a spec code: irfcl:USA | cofer:CI_USD:SHRO_PT | bis:CN."""
    kind, _, arg = code.partition(":")
    if kind == "irfcl":
        rows = get_csv(f"{IMF_SDMX}IMF.STA,IRFCL/{GOLD_COUNTRIES}.IRFCLDT1_IRFCL56V_FTO.*.M?lastNObservations=6", SDMX_CSV)
        return parse_irfcl_gold(rows, arg), "IMF International Reserves (IRFCL), gold as each country reports it"
    if kind == "cofer":
        cur, tr = arg.split(":")
        rows = get_csv(f"{IMF_SDMX}IMF.STA,COFER/G001.AFXRA.CI_USD+CI_T.SHRO_PT+NV_USD.Q?lastNObservations=6", SDMX_CSV)
        return parse_cofer(rows, cur, tr), "IMF COFER (currency composition of official reserves, world total)"
    rows = get_csv(f"https://stats.bis.org/api/v2/data/dataflow/BIS/WS_CBTA/1.0/Q.{arg}?lastNObservations=6&format=csv")
    return parse_bis_assets(rows, arg), "BIS central bank total assets (own currency)"

def get_trade(code):
    """Pure-ish. 'EXPCH:IMPCH' -> [(date, exports - imports in $ million)] on the months both series have."""
    ex, im = (dict(get_fred(x)) for x in code.split(":"))
    return [(d, ex[d] - im[d]) for d in sorted(ex) if d in im]

def build_economy(prev=None):
    old = {m["key"]: m for g in (prev or {}).get("groups", []) for m in g["members"]}   # last good file, for a series that fails right now
    groups, missing = [], [{"group": g, "name": n, "why": w} for g, n, w in ECON_MISSING]
    for gkey, gname, gshort, specs in ECON:
        mem = []
        for spec in specs:
            try:
                if spec[2] == "y":
                    try: intr = get(spec[3], "5m", "5d")
                    except Exception: intr = None
                    mem.append(econ_yahoo(spec, get(spec[3], "1d", "1mo"), intr)); time.sleep(0.3)
                elif spec[2] == "i":
                    mem.append(econ_fred(spec, get_imf(spec[3])))
                elif spec[2] == "m":
                    rows_, src_ = get_sdmx(spec[3]); mem.append(econ_fred(spec, rows_, src_))
                elif spec[2] == "t":
                    mem.append(econ_fred(spec, get_trade(spec[3]), "FRED (Census data): exports minus imports, " + spec[3]))
                else:
                    mem.append(econ_fred(spec, get_fred(spec[3])))
            except Exception as e:      # one dead series never blocks the rest, and is never faked
                print(f"economy {spec[1]} failed: {e}", file=sys.stderr)
                if spec[0] in old:      # keep its last real reading: it still carries its own as-of date, so the page
                    mem.append(dict(old[spec[0]], carried=True))   # says "closed / monthly Aug" and never passes it off as fresh
                else: missing.append({"group": gkey, "name": spec[1], "why": f"fetch failed: {e}"})
        groups.append({"key": gkey, "name": gname, "short": gshort, "members": mem})
    for g in groups:
        for m in g["members"]: m["short"] = ECON_SHORT.get(m["key"], m["name"])
    return {"generated_at": int(time.time()), "source": "Yahoo Finance (delayed futures and yields), FRED and the IMF World Economic Outlook (each series at its own release rhythm)",
            "groups": groups, "missing": missing}

def selfcheck():
    # two ET days: 09-24 (daily close 100) then 09-25 session 101 -> 103, one null bar
    t0 = int(datetime(2026, 9, 25, 9, 30, tzinfo=ET).timestamp())
    d24 = int(datetime(2026, 9, 24, 16, 0, tzinfo=ET).timestamp())
    intr = {"timestamp": [d24, t0, t0 + 300, t0 + 600],
            "indicators": {"quote": [{"close": [99.0, 101.0, None, 103.0], "volume": [500, 1200, None, None]}]}}
    daily = {"timestamp": [d24 - 86400, d24, t0], "indicators": {"quote": [{"close": [98.0, 100.0, 103.0]}]}}
    s = shape("sp500", "S&P 500", "^GSPC", intr, daily)
    assert s["session_date"] == "2026-09-25", s
    assert s["prev_close"] == 100.0, s          # the 09-24 close, not the 09-25 daily row
    assert s["bars"] == [[t0, 101.0, 1200], [t0 + 600, 103.0, None]], s   # prior day + null dropped; volume rides along
    assert s["last"] == 103.0 and s["last_time"] == t0 + 600
    # volume heartbeat: no volume field at all in the source -> every bar's volume is null (honest
    # empty state, never zero — zero would look like real, quiet trading)
    intr_nv = {"timestamp": [t0], "indicators": {"quote": [{"close": [101.0]}]}}
    s_nv = shape("sp500", "S&P 500", "^GSPC", intr_nv, daily)
    assert s_nv["bars"] == [[t0, 101.0, None]], s_nv["bars"]
    # every session carries the close of the day before it (09-24 <- 09-23's 98, 09-25 <- 09-24's 100)
    assert [(x["date"], x["prev_close"]) for x in s["sessions"]] == [("2026-09-24", 98.0), ("2026-09-25", 100.0)], s
    # a session with no daily close before it (09-22 here) is dropped, not guessed
    d22 = int(datetime(2026, 9, 22, 11, 0, tzinfo=ET).timestamp())
    s2 = shape("sp500", "S&P 500", "^GSPC", {"timestamp": [d22, t0], "indicators": {"quote": [{"close": [97.0, 101.0]}]}}, daily)
    assert [x["date"] for x in s2["sessions"]] == ["2026-09-25"], s2["sessions"]
    # central-bank parsers on the IMF/BIS CSV shapes (a unit slip is off by 1000x, a sector slip shows GBR's 0 t)
    ir = [dict(COUNTRY="GBR", SECTOR="S1X", TIME_PERIOD="2026-M08", OBS_VALUE="0"), dict(COUNTRY="GBR", SECTOR="S1XS1311", TIME_PERIOD="2026-M08", OBS_VALUE="9976041.279"),
          dict(COUNTRY="DEU", SECTOR="S1X", TIME_PERIOD="2026-M07", OBS_VALUE="107683051.528"), dict(COUNTRY="DEU", SECTOR="S1X", TIME_PERIOD="2026-M08", OBS_VALUE="107676802.209"),
          dict(COUNTRY="DEU", SECTOR="S1XS1311", TIME_PERIOD="2026-M08", OBS_VALUE="107676802.209")]
    assert parse_irfcl_gold(ir, "GBR") == [("2026-08-01", 9976041.279 / OZ_PER_TONNE)], "prefers S1XS1311 over a zero S1X"
    g = parse_irfcl_gold(ir, "DEU"); assert [d for d, _ in g] == ["2026-08-01"] and 3349 < g[0][1] < 3350, g
    cf = [dict(COUNTRY="G001", INDICATOR="AFXRA", FXR_CURRENCY="CI_USD", TYPE_OF_TRANSFORMATION=t, TIME_PERIOD=p, OBS_VALUE=v)
          for t, p, v in [("SHRO_PT", "2026-Q1", "57.17"), ("SHRO_PT", "2026-Q2", "56.70"), ("NV_USD", "2026-Q2", "7494549610004.36")]]
    assert parse_cofer(cf, "CI_USD", "SHRO_PT") == [("2026-01-01", 57.17), ("2026-04-01", 56.70)] and abs(parse_cofer(cf, "CI_USD", "NV_USD")[0][1] - 7.4945) < 1e-3
    bs = [dict(REF_AREA="GB", UNIT_MEASURE=u, UNIT_MULT="9", TIME_PERIOD="2026-Q2", OBS_VALUE=v) for u, v in [("XDC", "799.187"), ("XDC", "799.187"), ("USD", "1070.0")]]
    assert parse_bis_assets(bs, "GB") == [("2026-04-01", 799.187)], "own currency, one row per quarter"
    assert _per("2026-Q4") == "2026-10-01" and _per("2026-M08") == "2026-08-01"
    eo = lambda *a: econ_open(datetime(*a, tzinfo=ET))
    assert eo(2026, 10, 1, 3, 0) and eo(2026, 10, 2, 16, 59) and not eo(2026, 10, 2, 17, 0) and not eo(2026, 10, 3, 12, 0) \
        and not eo(2026, 10, 4, 17, 59) and eo(2026, 10, 4, 18, 0), "econ_open window"   # Fri 17:00 ET close .. Sun 18:00 ET open
    mo = lambda *a: market_open(datetime(*a, tzinfo=ET))
    assert mo(2026, 10, 1, 9, 30) and mo(2026, 10, 1, 16, 25) and not mo(2026, 10, 1, 9, 29) \
        and not mo(2026, 10, 1, 16, 26) and not mo(2026, 10, 3, 11, 0), "market_open window"   # Sat closed
    # companies: two members, one day on the index's clock [t0, t0+300, t0+600]
    sess = [{"date": "2026-09-25", "bars": [[t0, 1.0, 100], [t0 + 300, 1.0, None], [t0 + 600, 1.0, 5]]}]   # the REAL bar shape: [t, close, volume]
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
    sess2 = sess + [{"date": "2026-09-28", "bars": [[t0 + 3 * 86400, 1.0, None]]}]
    c2 = shape_companies([("AAA", "Ay", "Y"), ("EEE", "Ee", "Y")], {"AAA": 2e12, "EEE": 1e9}, sess2,
                         {"AAA": intr_c["AAA"] + [(t0 + 3 * 86400, 200.0)], "EEE": [(t0, 30.0), (t0 + 3 * 86400, 33.0)]},
                         {"AAA": [(d24, 200.0), (t0, 199.0)], "EEE": [(d23, 20.0), (t0, 30.0)]})
    assert c2["sessions"][0]["m"][1] is None, c2["sessions"][0]["m"]
    assert c2["sessions"][1]["m"] == [[50], [1000]], c2["sessions"][1]["m"]   # vs 09-25 closes 199 and 30
    # generalised to any index: the "index" field follows the key, not a hardcoded "sp500"
    c3 = shape_companies([("AAA", "Ay", "Y")], {"AAA": 1e12}, sess, {"AAA": intr_c["AAA"]}, daily_c, "dow")
    assert c3["index"] == "dow", c3["index"]
    # INDEX_CAP/ranking: nasdaq/russell trim to top N by precap BEFORE spending HTTP calls on prices
    assert INDEX_CAP == {"dow": 30, "sp500": 500, "nasdaq": 500, "russell": 500}, INDEX_CAP
    # sector labels: normalised once for every roster (nasdaq's short names join the GICS ones)
    assert norm_sector("Technology") == "Information Technology", norm_sector("Technology")
    assert norm_sector("Finance") == "Financials" and norm_sector("") == "Other", norm_sector("Finance")
    assert norm_sector("Health Care") == "Health Care", "canonical names pass through unchanged"
    # the fear gauge (VIX) reuses shape() itself, not a parallel parser — same function, key "vix"
    vs = shape("vix", "VIX", "^VIX", intr, daily)
    assert vs["key"] == "vix" and vs["last"] == 103.0, vs
    # IMF: projections (this year and later) are not readings; a missing year is dropped
    imf = {"values": {"D": {"W": {"2023": 90.8, "2024": 92, "2025": 93.9, "2026": 95.3, "2027": 97.2}}}}
    assert parse_imf(imf, "D", "W", 2026) == [("2023-01-01", 90.8), ("2024-01-01", 92.0), ("2025-01-01", 93.9)]
    # every ECON spec has a known source and rhythm (a typo'd "q" would silently land in the FRED branch)
    assert all(s[2] in "yfimt" and s[6] in ("5min", "weekly", "monthly", "quarterly", "yearly") for _, _, _, sp in ECON for s in sp)
    # economy: parse_fred drops '.' rows; a member is last-vs-the-close-before, dated by its own reading
    rows = parse_fred("observation_date,X\n2026-06-01,10\n2026-07-01,.\n2026-08-01,12.5\n")
    assert rows == [("2026-06-01", 10.0), ("2026-08-01", 12.5)], rows
    f = econ_fred(("x", "X", "f", "X", "pct", "u", "monthly"), rows)
    assert (f["prev"], f["last"], f["asof"], f["prev_asof"]) == (10.0, 12.5, "2026-08-01", "2026-06-01"), f
    yr = [(f"2025-{m:02d}-01", 100.0 + m) for m in range(1, 13)] + [("2026-01-01", 120.0), ("2026-02-01", 121.0)]
    assert econ_fred(("x", "X", "f", "X", "pct", "u", "monthly"), yr)["yoy"] == round((121 / 102 - 1) * 100, 2)   # Feb 26 vs Feb 25
    daily_e = {"timestamp": [d24, t0], "indicators": {"quote": [{"close": [100.0, 103.0]}]}}
    intr_e = {"timestamp": [t0 + 60, t0 + 360], "indicators": {"quote": [{"close": [104.0, 105.0]}]}}
    y = econ_yahoo(("g", "G", "y", "G=F", "pct", "u", "5min"), daily_e, intr_e)
    assert (y["prev"], y["last"], y["freq"], y["last_time"]) == (100.0, 105.0, "5min", t0 + 360), y   # newest intraday vs the close before today's bar
    y2 = econ_yahoo(("g", "G", "y", "G=F", "pct", "u", "5min"), daily_e, None)
    assert (y2["prev"], y2["last"], y2["freq"]) == (100.0, 103.0, "daily") and y2["bars"] == [], y2   # thin market: daily only, said so
    intr_m = dict(intr_e, meta={"previousClose": 104.5})
    assert econ_yahoo(("g", "G", "y", "G=F", "pct", "u", "5min"), daily_e, intr_m)["prev"] == 104.5   # roll: Yahoo's settle for this contract beats the spliced daily row
    fz = {"timestamp": [d24 - 3 * 86400, d24 - 2 * 86400, d24, t0], "indicators": {"quote": [{"close": [100.0, 100.0, 100.0, 100.0]}]}}
    intr_fz = {"timestamp": [d24 + 60, t0 + 60], "indicators": {"quote": [{"close": [107.0, 108.0]}]}}
    assert econ_yahoo(("g", "G", "y", "G=F", "pct", "u", "5min"), fz, intr_fz)["prev"] == 107.0   # frozen settlement: last real print, not +8%
    try: econ_yahoo(("g", "G", "y", "G=F", "pct", "u", "5min"), fz, None); assert False
    except ValueError: pass                                                                       # frozen and nothing else: no move invented
    try: econ_yahoo(("g", "G", "y", "G=F", "pct", "u", "5min"), {"timestamp": [t0], "indicators": {"quote": [{"close": [1.0]}]}}, None); assert False
    except ValueError: pass                                                                       # one close is not a move
    try: econ_fred(("x", "X", "f", "X", "pct", "u", "monthly"), [("2026-08-01", 1.0)]); assert False
    except ValueError: pass                                                                       # nor is one reading
    # a source that is down: the series keeps its last REAL reading (marked carried, its own date intact);
    # one with no earlier reading is listed as missing with the reason; nothing is invented either way
    g = globals(); real = (g["get"], g["get_fred"])
    def down(*a, **k): raise OSError("down")
    g["get"], g["get_fred"] = down, down
    try:
        prev_e = {"groups": [{"members": [{"key": "brent", "name": "Brent crude", "last": 98.6, "asof": "2026-09-28", "freq": "5min"}]}]}
        out = build_economy(prev_e)
    finally:
        g["get"], g["get_fred"] = real
    energy = out["groups"][0]["members"]
    assert [m["key"] for m in energy] == ["brent"] and energy[0]["carried"] and energy[0]["last"] == 98.6, energy
    assert any(x["name"] == "WTI crude" and "down" in x["why"] for x in out["missing"]) and not any(x["name"] == "Brent crude" for x in out["missing"]), out["missing"]
    print("✓ fetch selfcheck: 34 asserts")

if __name__ == "__main__":
    if "--selfcheck" in sys.argv: selfcheck(); sys.exit(0)
    if "--economy" in sys.argv:
        here = pathlib.Path(__file__).parent / "data"
        try: prev = json.loads((here / "economy.json").read_text())
        except Exception: prev = None
        data = build_economy(prev)
        (here / "economy.json").write_text(json.dumps(data, separators=(",", ":")) + "\n")
        n = sum(len(g["members"]) for g in data["groups"])
        print(f'economy: {n} series live in {len(data["groups"])} groups, {len(data["missing"])} not live -> data/economy.json')
        sys.exit(0)
    if "--market-open" in sys.argv:
        sys.exit(0 if market_open() else 1)
    if "--econ-open" in sys.argv:
        sys.exit(0 if econ_open() else 1)
    if "--companies" in sys.argv:
        here = pathlib.Path(__file__).parent / "data"
        i = sys.argv.index("--companies")
        key = sys.argv[i + 1] if len(sys.argv) > i + 1 and sys.argv[i + 1] in ROSTERS else "sp500"
        fname = "companies.json" if key == "sp500" else f"companies-{key}.json"   # sp500 URL unchanged
        data = build_companies(json.loads((here / "market.json").read_text()), key)
        (here / fname).write_text(json.dumps(data, separators=(",", ":")) + "\n")
        last = data["sessions"][-1]; up = sum(1 for x in last["m"] if x and x[-1] > 0)
        print(f'companies[{key}]: {len(data["companies"])} members, {len(data["sessions"])} days, '
              f'{last["date"]}: {up} up of {sum(1 for x in last["m"] if x)} priced -> data/{fname}')
        sys.exit(0)
    out = pathlib.Path(sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else
                       pathlib.Path(__file__).parent / "data" / "market.json")
    data = build()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, separators=(",", ":")) + "\n")
    for i in data["indexes"]:
        print(f'{i["name"]:13} {i["session_date"]} last {i["last"]:>10} prev {i["prev_close"]:>10} '
              f'{(i["last"]/i["prev_close"]-1)*100:+.2f}%  {len(i["bars"])} bars')
