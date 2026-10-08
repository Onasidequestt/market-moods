#!/bin/sh
# The page in REAL Chromium (software WebGL) at phone and desktop width.
#  1. with data: status says live or replaying, four cards carry a % and a level,
#     the mood word is set, and the lamp drew coloured wax (not just the dark background)
#  2. without data: the honest "couldn't load" notice shows and NO wax is drawn
#  3. inside the S&P 500 (#cell): the caption's counts (rising / against the index) match a
#     count made HERE from the data files at the page's own moment; the blobs are really drawn;
#     "All 500" shows every priced member; with no company file there is no door and no specks
# usage: sh browser-check.sh     (serves this folder on 127.0.0.1:8766 while it runs)
cd "$(dirname "$0")" || exit 2
B="$HOME/.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.42/chrome-headless-shell-mac-arm64/chrome-headless-shell"
[ -x "$B" ] || B="$HOME/Library/Caches/ms-playwright/chromium_headless_shell-1148/chrome-mac/headless_shell"   # 10-07: the puppeteer cache was cleaned off the disk; Playwright's shell is the same binary
[ -x "$B" ] || { echo "✘ browser-check: chrome-headless-shell not found"; exit 2; }
T=$(mktemp -d); mkdir -p "$T/nodata"; cp index.html mood.js "$T/nodata/"
# a browser with no page fullscreen (iPhone Safari): same page with requestFullscreen removed
mkdir -p "$T/nofs"; cp mood.js "$T/nofs/"
sed 's|<head>|<head><script>Element.prototype.requestFullscreen = undefined;</script>|' index.html > "$T/nofs/index.html"
# the index data but no company file: the inside view must not pretend
mkdir -p "$T/nocomp/data"; cp index.html mood.js "$T/nocomp/"; cp data/market.json "$T/nocomp/data/"
# how many indexes actually have a companies file right now (sp500 always companies.json; the
# other three are companies-<key>.json) — the door count check follows what's really on disk
NDOORS=$(ls data/companies.json data/companies-dow.json data/companies-nasdaq.json data/companies-russell.json 2>/dev/null | wc -l | tr -d ' ')
# the days the company file covers: its last day, and its worst S&P 500 day (a down day inside and out)
read -r D_LAST D_DOWN <<EOF2
$(python3 -c "
import json; m=json.load(open('data/market.json')); c=json.load(open('data/companies.json'))
sp=[i for i in m['indexes'] if i['key']=='sp500'][0]; ds=[x['date'] for x in c['sessions']]
mv={x['date']:x['bars'][-1][1]/x['prev_close'] for x in sp['sessions'] if x['date'] in ds}
print(ds[-1], min(mv, key=mv.get))")
EOF2
# a shut, quiet market: the same data with every volume reading and the VIX removed — the lamp must
# be exactly still and show no fear (honest zero), companies kept so the cell view can be checked
mkdir -p "$T/quiet/data"; cp index.html mood.js "$T/quiet/"; cp data/companies*.json "$T/quiet/data/"
python3 - "$T/quiet/data" <<'EOFQ'
import json, sys
m = json.load(open("data/market.json")); m.pop("vix", None)
def strip(bars): return [[b[0], b[1], None] for b in bars]
for i in m["indexes"]:
    i["bars"] = strip(i["bars"])
    for x in i.get("sessions", []): x["bars"] = strip(x["bars"])
json.dump(m, open(sys.argv[1] + "/market.json", "w"))
EOFQ
python3 -m http.server 8766 --bind 127.0.0.1 >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
sleep 1
ln -s "$T/nodata" ./.nodata-check 2>/dev/null; ln -s "$T/nofs" ./.nofs-check 2>/dev/null; ln -s "$T/nocomp" ./.nocomp-check 2>/dev/null; ln -s "$T/quiet" ./.quiet-check 2>/dev/null
trap 'kill $SRV 2>/dev/null; rm -rf "$T"; rm -f ./.nodata-check ./.nofs-check ./.nocomp-check ./.quiet-check' EXIT
shoot() { # $1 size  $2 url  $3 out
  P=$(mktemp -d)
  "$B" --headless --user-data-dir="$P" --use-angle=swiftshader --enable-unsafe-swiftshader --hide-scrollbars \
    --window-size="$1" --virtual-time-budget=5000 --screenshot="$3.png" "$2" >/dev/null 2>&1
  "$B" --headless --user-data-dir="$P" --use-angle=swiftshader --enable-unsafe-swiftshader \
    --window-size="$1" --virtual-time-budget=5000 --dump-dom "$2" 2>/dev/null > "$3.html"
  rm -rf "$P"
}
RC=0
for SIZE in 390,844 1440,900; do
  shoot $SIZE "http://127.0.0.1:8766/#at=12:10" "$T/ok"
  shoot $SIZE "http://127.0.0.1:8766/.nodata-check/" "$T/no"
  shoot $SIZE "http://127.0.0.1:8766/#day=2026-09-23&at=15:55" "$T/down"
  shoot $SIZE "http://127.0.0.1:8766/#day=2026-09-21&at=15:55" "$T/up"
  shoot $SIZE "http://127.0.0.1:8766/#day=2026-09-25&at=09:30" "$T/open"
  "$B" --headless --user-data-dir="$(mktemp -d)" --virtual-time-budget=3000 --dump-dom "http://127.0.0.1:8766/.nofs-check/" 2>/dev/null > "$T/nofs.html"
  shoot $SIZE "http://127.0.0.1:8766/#cell&day=$D_LAST&at=12:10" "$T/cell"
  shoot $SIZE "http://127.0.0.1:8766/#cell&top=500&day=$D_DOWN&at=15:00" "$T/cell500"
  shoot $SIZE "http://127.0.0.1:8766/.nocomp-check/#cell&day=$D_LAST&at=12:10" "$T/nocomp"
  shoot $SIZE "http://127.0.0.1:8766/#cell&idx=dow&day=$D_LAST&at=12:10" "$T/celldow"
  shoot $SIZE "http://127.0.0.1:8766/#cell&idx=nasdaq&top=500&day=$D_LAST&at=12:10" "$T/cellnasdaq"
  "$B" --headless --user-data-dir="$(mktemp -d)" --use-angle=swiftshader --enable-unsafe-swiftshader --window-size="$SIZE" \
    --virtual-time-budget=5000 --dump-dom "http://127.0.0.1:8766/#cell&size=move&day=$D_LAST&at=12:10" 2>/dev/null > "$T/cellmove.html"
  python3 - "$T" "$SIZE" "$D_LAST" "$D_DOWN" "$NDOORS" <<'EOF' || RC=1
import re, sys, html
from PIL import Image
t, size = sys.argv[1], sys.argv[2]
def wax(png):  # count saturated, bright pixels: the lamp's wax, never the dark background or glass cards
    im = Image.open(png).convert("RGB"); w, h = im.size
    px = im.crop((0, int(h * .2), w, int(h * .75))).resize((w // 4, int(h * .55) // 4)).getdata()
    return sum(1 for r, g, b in px if max(r, g, b) > 150 and max(r, g, b) - min(r, g, b) > 70)
def text(f): return html.unescape(re.sub(r"<[^>]+>", " ", open(f).read()))
bad = []
dom = open(f"{t}/ok.html").read(); tx = text(f"{t}/ok.html")
if not re.search(r"Live, delayed|replaying", tx): bad.append("status is not live/replaying")
pcts = re.findall(r'class="pct num"[^>]*>([+−]\d+\.\d\d%)<', dom)
lvls = re.findall(r'class="lvl num">([\d,]+\.\d\d)<', dom)
if len(pcts) != 4 or len(lvls) != 4: bad.append(f"cards: {len(pcts)} pcts, {len(lvls)} levels")
if not re.search(r'id="moodWord"[^>]*>(Fearful|Uneasy|Calm|Buoyant|Euphoric)<', dom): bad.append("no mood word")
tagsrc = (re.search(r'<div class="tags" id="tags"[^>]*>(.*?)</div>', dom, re.S) or [None, ""])[1]   # the blob labels only
tags = [((re.search(r'style="([^"]*)"', a) or [None, ""])[1], n) for a, n in
        re.findall(r'<span((?: (?:class|title|style)="[^"]*")*)>(Dow|S&amp;P 500|Nasdaq|Russell)</span>', tagsrc)]
# a label is either positioned (inline left + visible) or still hidden by the .tags span rule
hidden_default = re.search(r"\.tags span \{[^}]*visibility: hidden", dom) is not None
stray = [n for st, n in tags if ("left:" not in st) and not (hidden_default and "visible" not in st)]
if not hidden_default: bad.append(".tags span rule no longer hides labels before their first position")
if len(tags) != 4: bad.append(f"{len(tags)} blob labels, want 4")
if stray: bad.append(f"labels shown with no position (pile up top-left): {stray}")
w_ok = wax(f"{t}/ok.png")
if w_ok < 400: bad.append(f"lamp drew only {w_ok} wax pixels")
tn = text(f"{t}/no.html"); w_no = wax(f"{t}/no.png")
if "Couldn't load the market data" not in tn: bad.append("no-data notice missing")
if w_no > 20: bad.append(f"no-data page still drew {w_no} wax pixels (fake liveliness)")
# a real down day (Wed 09-23: all four fell) picked by link: the day chip is pressed, the mood is
# fearful/uneasy, every card is negative, and the status names that day
dn = open(f"{t}/down.html").read()
chips = re.findall(r'class="btn day" aria-pressed="(true|false)"[^>]*>([^<]+)<', dn)
if len(chips) < 2 or [c for p, c in chips if p == "true"] != ["Wed 23"]: bad.append(f"day chips {chips}, want Wed 23 pressed")
dp = re.findall(r'class="pct num"[^>]*>([+−]\d+\.\d\d%)<', dn)
if len(dp) != 4 or any(not x.startswith("−") for x in dp): bad.append(f"down day cards {dp}, want four negatives")
if not re.search(r'id="moodWord"[^>]*>(Fearful|Uneasy)<', dn): bad.append("down day mood is not Fearful/Uneasy")
if "replaying Wed, Sep 23" not in dn: bad.append("status does not name Wed, Sep 23")
# wax must stay between the caption and the footer: count wax in the caption's last 22px and in the
# 34px strip under the footer's top edge (day chips / timeline), both neutral grey by design
def strip_wax(png, y0, y1):
    im = Image.open(png).convert("RGB"); w, h = im.size; sc = h / int(size.split(",")[1])
    box = im.crop((0, max(0, int(y0 * sc)), w, min(h, int(y1 * sc))))
    return sum(1 for r, g, b in box.getdata() if max(r, g, b) > 150 and max(r, g, b) - min(r, g, b) > 70)
for nm in ("ok", "down", "up"):
    m = re.search(r'id="lamp"[^>]*data-edges="(\d+),(\d+)"', open(f"{t}/{nm}.html").read())
    if not m: bad.append(f"{nm}: page did not report its edges"); continue
    top, foot = int(m[1]), int(m[2])
    cw, fw = strip_wax(f"{t}/{nm}.png", top - 22, top), strip_wax(f"{t}/{nm}.png", foot, foot + 34)
    if cw > 30 or fw > 30: bad.append(f"{nm}: wax over the caption ({cw}px) or the footer ({fw}px)")
# at the opening bell there is no hour to measure: each card says "just opened", never "just opened last hour"
ch = re.findall(r'class="chop"[^>]*>([^<]*)<', re.sub(r"<script\b.*?</script>", "", open(f"{t}/open.html").read(), flags=re.S))
if ch != ["just opened"] * 4: bad.append(f"opening-bell chop labels {ch}, want four 'just opened'")
# the full-screen button shows where the browser can fill the screen, and is hidden where it can't
fs_ok = re.search(r'<button[^>]*id="fsBtn"[^>]*>', open(f"{t}/ok.html").read())
fs_no = re.search(r'<button[^>]*id="fsBtn"[^>]*>', open(f"{t}/nofs.html").read())
if not fs_ok or "hidden" in fs_ok[0]: bad.append("full-screen button hidden in a browser that supports it")
if not fs_no or "hidden" not in fs_no[0]: bad.append("full-screen button shown where fullscreen is missing (dead button)")
# ---- inside each index ----
import json, math
mk = json.load(open("data/market.json"))
CO_FILE = {"dow": "companies-dow.json", "sp500": "companies.json", "nasdaq": "companies-nasdaq.json", "russell": "companies-russell.json"}
CO = {}
for k, fn in CO_FILE.items():
    try: CO[k] = json.load(open(f"data/{fn}"))
    except FileNotFoundError: pass
co = CO.get("sp500")
sp = [i for i in mk["indexes"] if i["key"] == "sp500"][0]
def expect(key, date, p, top):  # the caption's numbers, counted here from the files (not from the page)
    ix = [i for i in mk["indexes"] if i["key"] == key][0]
    ss = [x for x in ix["sessions"] if x["date"] == date][0]; b = ss["bars"]
    i = min(max(int(p), 0), len(b) - 1); j = min(i + 1, len(b) - 1); f = min(max(p - i, 0), 1)
    ipct = ((b[i][1] + (b[j][1] - b[i][1]) * f) / ss["prev_close"] - 1) * 100
    coK = CO[key]
    S = [x for x in coK["sessions"] if x["date"] == date][0]
    rows = [r for r in S["m"] if r]; rows = rows if top >= 500 else rows[:top]
    def q(r):
        k = min(max(int(p), 0), len(r) - 1); l = min(k + 1, len(r) - 1); return (r[k] + (r[l] - r[k]) * min(max(p - k, 0), 1)) / 100
    qs = [q(r) for r in rows]
    agl = [k for k, x in enumerate(qs) if abs(x) >= .1 and abs(ipct) >= .1 and (x > 0) != (ipct > 0)]
    names = [c["s"] for c, r in zip(coK["companies"], S["m"]) if r]
    return len(rows), sum(1 for x in qs if x > 0), len(agl), ipct, (names[agl[0]] if agl else None)
def cell_check(nm, key, date, top):
    dom = open(f"{t}/{nm}.html").read()
    if 'class="incell"' not in dom: bad.append(f"{nm}: #cell link did not open the inside view"); return None
    sub = re.search(r'id="cellSub">(.*?) ([+−])(\d+\.\d\d)% · (\d+) of (\d+) companies rising · (\d+) moving against it(?: \(biggest: ([A-Z.-]+) [+−][\d.]+%\))?<', dom)
    pos = re.search(r'id="cell"[^>]*data-pos="([\d.]+)"', dom); geo = re.search(r'id="cell"[^>]*data-cell="(\d+),(\d+),(\d+)"', dom)
    nodes = re.search(r'id="cell"[^>]*data-nodes="(\d+)"', dom)
    if not (sub and pos and geo and nodes): bad.append(f"{nm}: caption/pos/geometry missing"); return None
    n, up, ag, ipct, bigname = expect(key, date, float(pos[1]), top)
    if sub[7] != bigname: bad.append(f"{nm}: caption names {sub[7]} as the biggest against the index; the files say {bigname}")
    got = (int(sub[5]), int(sub[4]), int(sub[6]))
    if got != (n, up, ag): bad.append(f"{nm}: caption says {got[1]} of {got[0]} rising, {got[2]} against; the files say {up} of {n}, {ag}")
    ix_pct = float(sub[3]) * (-1 if sub[2] == "−" else 1)
    if abs(ix_pct - ipct) > 0.011: bad.append(f"{nm}: {key} {ix_pct}% vs {ipct:.3f}% from the file")
    if int(nodes[1]) != n: bad.append(f"{nm}: drew {nodes[1]} blobs, want {n}")
    # the blobs are really painted: bright, saturated pixels inside the membrane (its fill is dim)
    im = Image.open(f"{t}/{nm}.png").convert("RGB"); W, H = im.size; sc = H / int(size.split(",")[1])
    cx, cy, R = (int(v) * sc for v in geo.groups()); px = im.load(); lit = tot = 0
    for y in range(int(cy - R), int(cy + R), 3):
        for x in range(int(cx - R), int(cx + R), 3):
            if 0 <= x < W and 0 <= y < H and math.hypot(x - cx, y - cy) < R * 0.9:
                tot += 1; r_, g_, b_ = px[x, y]
                if max(r_, g_, b_) > 150 and max(r_, g_, b_) - min(r_, g_, b_) > 70: lit += 1
    if lit < tot * 0.15: bad.append(f"{nm}: only {lit}/{tot} sampled pixels are wax inside the membrane")
    return f"{nm} {got[1]}/{got[0]} up, {got[2]} against, {lit * 100 // max(tot, 1)}% lit"
c1 = cell_check("cell", "sp500", sys.argv[3], 50); c2 = cell_check("cell500", "sp500", sys.argv[4], 500)
if c2 and int(re.search(r"of (\d+) companies", open(f"{t}/cell500.html").read())[1]) <= 500 and \
   sum(1 for r in [x for x in co["sessions"] if x["date"] == sys.argv[4]][0]["m"] if r) > 500:
    bad.append("cell500: 'All 500' stopped at 500, not every priced member")
# Dow: only 30 members — must show ALL 30, never a subset, and say so honestly (no Show switch)
cdow = cell_check("celldow", "dow", sys.argv[3], 500) if "dow" in CO else None
if cdow:
    dd = open(f"{t}/celldow.html").read()
    if 'id="cellShowSeg" hidden' not in dd: bad.append("celldow: the pointless 50/100/500 switch still shows for a 30-member index")
    if "only 30 members" not in html.unescape(dd): bad.append("celldow: no honest 'only 30 members' note")
    n30 = re.search(r'id="cell"[^>]*data-nodes="(\d+)"', dd)
    if not n30 or int(n30[1]) != 30: bad.append(f"celldow: drew {n30 and n30[1]} of the Dow's 30, want all 30")
# Nasdaq: top 500 by market value out of 3,000+ listings — the switch still works, capped at 500
cnas = cell_check("cellnasdaq", "nasdaq", sys.argv[3], 500) if "nasdaq" in CO else None
# the key says what size means right now: company value by default, the move after the switch
for nm, want in (("cell", "bigger = bigger company"), ("cellmove", "bigger = bigger move")):
    kl = re.search(r'id="cellKeyLong">([^<]*)<', open(f"{t}/{nm}.html").read())
    if not kl or want not in kl[1]: bad.append(f"{nm}: key does not say '{want}' ({kl and kl[1][:80]})")
okd = open(f"{t}/ok.html").read()
ndoors_want = int(sys.argv[5])
ndoors_got = len(re.findall(r'class="idx hasdoor"', okd))
if ndoors_got != ndoors_want: bad.append(f"{ndoors_got} 'Look inside' doors, want {ndoors_want} (one per companies file on disk)")
# the blob labels are doors too (critic 09-28: the Russell label opened an empty view): same count
# ponytail: taps are not simulated here (dump-dom cannot click); every tap path goes through the one
# canOpen() gate that sets these classes, so a wrong count is the visible symptom. Upgrade path: a CDP
# click on each label in a scripted browser session.
tagd = re.search(r'id="tags"[^>]*>(.*?)</div>', okd, re.S)
ntag = len(re.findall(r'<span[^>]*\bclass="door"', tagd[1])) if tagd else -1
if ntag != ndoors_want: bad.append(f"{ntag} blob labels open an inside view, want {ndoors_want} (one per companies file on disk)")
sk = re.search(r'id="cell"[^>]*data-specks="(\d+)"', okd)
if not sk or int(sk[1]) != 0: bad.append(f"lamp: {sk and sk[1]} specks in an index blob, want none (Clark 10-07: all four blobs alike)")
ncd = open(f"{t}/nocomp.html").read()
if 'class="idx hasdoor"' in ncd or 'class="incell"' in ncd: bad.append("no company file, yet the door/inside view shows")
if re.search(r'<span[^>]*\bclass="door"', ncd): bad.append("no company file, yet a blob label is a door")
if re.search(r'data-specks="[1-9]', ncd): bad.append("no company file, yet specks are drawn (fake liveliness)")
if wax(f"{t}/nocomp.png") < 400: bad.append("no company file broke the lamp itself")
if bad: print(f"✘ browser-check {size}: " + "; ".join(bad)); sys.exit(1)
print(f"✓ browser-check {size} (real Chromium): cards {pcts} · wax {w_ok}px · no-data notice ✓, wax {w_no}px · Wed 23 {dp} · {c1} · {c2} · {cdow} · {cnas} · {ndoors_got} doors")
EOF
done

# ---- no-overlap rung: caption/note text must never collide with the controls row below it,
# at any phone width 320-430, for every index that has a door (celldow/cellnasdaq/cell=sp500) ----
for W in 320 390 430; do
  shoot "$W,844" "http://127.0.0.1:8766/#cell&idx=dow&day=$D_LAST&at=12:10" "$T/ov_dow_$W"
  shoot "$W,844" "http://127.0.0.1:8766/#cell&idx=nasdaq&day=$D_LAST&at=12:10" "$T/ov_nas_$W"
  shoot "$W,844" "http://127.0.0.1:8766/#cell&day=$D_LAST&at=12:10" "$T/ov_sp_$W"
done
python3 - "$T" <<'EOF' || RC=1
import re, sys
t = sys.argv[1]
bad = []
for nm in ("ov_dow_320", "ov_dow_390", "ov_dow_430", "ov_nas_320", "ov_nas_390", "ov_nas_430", "ov_sp_320", "ov_sp_390", "ov_sp_430"):
    dom = open(f"{t}/{nm}.html").read()
    nb = re.search(r'data-notice-box="(-?\d+),(-?\d+),(-?\d+),(-?\d+)"', dom)
    cb = re.search(r'data-ctl-box="(-?\d+),(-?\d+),(-?\d+),(-?\d+)"', dom)
    if not (nb and cb): bad.append(f"{nm}: notice/ctl box not reported"); continue
    nl, nt, nr, nn_ = (int(x) for x in nb.groups())
    cl, ctp, cr, cb_ = (int(x) for x in cb.groups())
    # standard rectangle overlap test: they intersect if they overlap on BOTH axes
    overlap = nl < cr and cl < nr and nt < cb_ and ctp < nn_
    if overlap: bad.append(f"{nm}: notice box ({nl},{nt},{nr},{nn_}) overlaps controls box ({cl},{ctp},{cr},{cb_})")
if bad: print("✘ browser-check no-overlap: " + "; ".join(bad)); sys.exit(1)
print("✓ browser-check no-overlap: caption/note never collides with controls at 320/390/430 (dow/nasdaq/sp500)")
EOF

# ---- help dialog must open scrolled to the TOP on a phone (autofocus on Close must not drag
# the dialog's own scroll down past the first definitions) ----
shoot 390,844 "http://127.0.0.1:8766/#help" "$T/help390"
python3 - "$T" <<'EOF' || RC=1
import re, sys
t = sys.argv[1]
dom = open(f"{t}/help390.html").read()
m = re.search(r'data-help-scroll="(\d+)"', dom)
if not m: print("✘ browser-check help-scroll: scrollTop not reported"); sys.exit(1)
st = int(m[1])
if st != 0: print(f"✘ browser-check help-scroll: dialog opened at scrollTop {st}, want 0"); sys.exit(1)
print("✓ browser-check help-scroll: help dialog opens at scrollTop 0 on phone")
EOF


# ---- sectors as organs: the cell view groups companies into sector clusters; the drawn organ
# count must match the number of DISTINCT (normalised) sectors actually present among that day's
# priced companies — counted independently, here, from the data file, not from the page ----
shoot 390,844 "http://127.0.0.1:8766/#cell&idx=dow&day=$D_LAST&at=12:10" "$T/org_dow"
python3 - "$T" <<'EOF' || RC=1
import json, re, sys
t = sys.argv[1]
ALIAS = {"Technology": "Information Technology", "Finance": "Financials",
         "Basic Materials": "Materials", "Telecommunications": "Communication Services",
         "Miscellaneous": "Other", "": "Other"}
co = json.load(open("data/companies-dow.json"))
mk = json.load(open("data/market.json"))
ix = [i for i in mk["indexes"] if i["key"] == "dow"][0]
S = [x for x in co["sessions"] if x["date"] == ix["session_date"]][-1]
priced_secs = {ALIAS.get(c["sec"], c["sec"]) for c, r in zip(co["companies"], S["m"]) if r}
dom = open(f"{t}/org_dow.html").read()
m = re.search(r'id="cell"[^>]*data-sectors="(\d+)"', dom)
bad = []
if not m: bad.append("no data-sectors reported")
elif int(m[1]) != len(priced_secs): bad.append(f"drew {m[1]} sector organs, the Dow's priced companies span {len(priced_secs)} ({sorted(priced_secs)})")
if bad: print("✘ browser-check sectors: " + "; ".join(bad)); sys.exit(1)
print(f"✓ browser-check sectors: {m[1]} organs, matches {len(priced_secs)} distinct sectors in the Dow's data")
EOF


# ---- label boxes (real Chromium): the page exposes every sector tag's box and every blob it
# painted (data-labels / data-blobs, as painted this frame). No tag may touch a blob or another tag,
# and none may leave the canvas — checked at phone and desktop width, in all three doored views.
# A view where too few tags survive is a fail too (else "drop everything" would pass vacuously).
for SIZE in 390,844 1440,900; do
  shoot $SIZE "http://127.0.0.1:8766/#cell&idx=dow&day=$D_LAST&at=12:10" "$T/lb_dow_$SIZE"
  shoot $SIZE "http://127.0.0.1:8766/#cell&day=$D_LAST&at=12:10" "$T/lb_sp_$SIZE"
  shoot $SIZE "http://127.0.0.1:8766/#cell&idx=nasdaq&day=$D_LAST&at=12:10" "$T/lb_nas_$SIZE"
done
python3 - "$T" <<'EOF' || RC=1
import re, sys, html
t = sys.argv[1]; bad = []; rows = []
for size in ("390,844", "1440,900"):
    for v in ("dow", "sp", "nas"):
        dom = html.unescape(open(f"{t}/lb_{v}_{size}.html").read())
        g = lambda k: (re.search(rf'id="cell"[^>]*data-{k}="([^"]*)"', dom) or [None, None])[1]
        L, Bl, C = g("labels"), g("blobs"), g("canvas")
        if L is None or Bl is None or C is None: bad.append(f"{v}@{size}: page did not report label/blob boxes"); continue
        W, H = map(float, C.split(","))
        labs = [tuple(map(float, x.split(","))) for x in L.split(";") if x]
        blobs = [tuple(map(float, x.split(","))) for x in Bl.split(";") if x]
        need = 3 if size.startswith("390") else 4
        if len(labs) < need: bad.append(f"{v}@{size}: only {len(labs)} sector tags survive, want >= {need}")
        if not blobs: bad.append(f"{v}@{size}: no blobs reported")
        for i, b in enumerate(labs):
            if b[0] < 0 or b[1] < 0 or b[2] > W or b[3] > H: bad.append(f"{v}@{size}: tag {i} {b} leaves the {W:.0f}x{H:.0f} canvas")
            for j, o in enumerate(labs[:i]):
                if b[0] < o[2] and b[2] > o[0] and b[1] < o[3] and b[3] > o[1]: bad.append(f"{v}@{size}: tags {j} and {i} overlap")
            for (x, y, r) in blobs:
                qx, qy = max(b[0], min(x, b[2])), max(b[1], min(y, b[3]))
                if (qx - x) ** 2 + (qy - y) ** 2 < r * r: bad.append(f"{v}@{size}: tag {i} {b} covers a blob at ({x:.0f},{y:.0f}) r{r:.0f}"); break
        rows.append(f"{v}@{size.split(',')[0]}:{len(labs)}tags/{len(blobs)}blobs")
if bad: print("✘ browser-check labels: " + "; ".join(bad[:6])); sys.exit(1)
print("✓ browser-check labels: no tag touches a blob or another tag or leaves the canvas (" + ", ".join(rows) + ")")
EOF


# ---- vitals: the fear gauge and the heartbeat must be VISIBLE, not just present. Every expected
# number is recomputed HERE from data/market.json (VIX level -> fear; the last 6 bars' combined
# volume -> pulse amplitude) and must match what the page painted; the always-visible readout on
# the mood block must say the same thing in words. A shut, quiet market (no volume, no vix: the
# `.quiet-check` fixture) must be a hard zero: amplitude exactly 0, radius factor exactly 1,
# no sector halo moving, no fear line. ----
shoot 390,844 "http://127.0.0.1:8766/#at=12:10&help" "$T/vit_ok"
shoot 390,844 "http://127.0.0.1:8766/.quiet-check/#at=12:10&help" "$T/vit_quiet"
shoot 390,844 "http://127.0.0.1:8766/#cell&idx=dow&day=$D_LAST&at=12:10" "$T/vit_cell"
shoot 390,844 "http://127.0.0.1:8766/.quiet-check/#cell&idx=dow&day=$D_LAST&at=12:10" "$T/vit_cellq"
python3 - "$T" <<'EOF' || RC=1
import json, re, sys, html, datetime, zoneinfo
t = sys.argv[1]; bad = []
mk = json.load(open("data/market.json"))
clamp = lambda x, lo, hi: max(lo, min(hi, x))
def body(f): return html.unescape(open(f"{t}/{f}.html").read())
def num(dom, k): m = re.search(rf'data-{k}="([\d.]+)"', dom); return float(m[1]) if m else None
def text(dom): return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", dom))
# --- with data
dom = body("vit_ok"); tx = text(dom)
vix = mk.get("vix", {}).get("last")
fear, amp, pulse = num(dom, "fear"), num(dom, "pulseamp"), num(dom, "pulse")
word = None
if vix is None: bad.append("market.json has no vix: cannot verify the fear gauge (not a pass)")
else:
    want = clamp((vix - 12) / 18, 0, 1)
    if fear is None or abs(fear - want) > 0.005: bad.append(f"data-fear={fear}, VIX {vix} says {want:.4f}")
    if 14 <= vix < 30 and want < 0.1: bad.append(f"fear {want:.3f} is below visible on a normal-level VIX")
    word = "calm" if vix < 14 else "watchful" if vix < 20 else "nervous" if vix < 30 else "fearful"
    if f"Fear {round(vix)} · {word}" not in tx: bad.append(f"mood block does not read 'Fear {round(vix)} · {word}'")
    if f"VIX {vix:.1f}, {word}" not in tx: bad.append(f"help does not state today's reading 'VIX {vix:.1f}, {word}'")
    if not re.search(r"12 or below.*full at 30", tx): bad.append("help does not state the 12 / 30 thresholds")
# expected pulse level: combined volume of the 6 bars up to the page's start bar, per volumeLevel()
bars = mk["indexes"][0]["bars"]
def hhmm(u):
    d = datetime.datetime.fromtimestamp(u, zoneinfo.ZoneInfo("America/New_York")); return d.hour * 60 + d.minute
i = next((k for k, b in enumerate(bars) if hhmm(b[0]) >= 12 * 60 + 10), len(bars) - 1)
comb = []
for k in range(max(0, i - 5), i + 1):
    tot = sum((ix["bars"][k][2] or 0) for ix in mk["indexes"] if k < len(ix["bars"])); comb.append(tot or None)
v = [x for x in comb if x]; lvl = 0 if len(v) < 2 else min(v[-1] / (sum(v) / len(v)), 2) / 2
wamp = 0.01 + 0.05 * lvl if lvl > 0 else 0
if lvl == 0: bad.append("no volume at the 12:10 bar: cannot verify the heartbeat (not a pass)")
if amp is None or abs(amp - wamp) > 0.004: bad.append(f"data-pulseamp={amp}, volume says {wamp:.4f}")
if amp is not None and amp < 0.02: bad.append(f"pulse amplitude {amp:.4f} < 2%: the heartbeat is not visible")
if pulse is not None and amp is not None and abs(pulse - 1) > amp + 1e-4: bad.append(f"pulse {pulse} outside 1 +- {amp}")
vw = "quiet" if lvl < .35 else "normal" if lvl < .65 else "busy"
if f"Volume {vw}" not in tx: bad.append(f"mood block does not read 'Volume {vw}'")
if f"volume {vw}, breathing" not in tx: bad.append("help does not state today's volume reading")
# --- sector pulse in the cell (with data): organs beat on their own phases, visibly
sp = re.search(r'id="cell"[^>]*data-spulse="([^"]*)"', body("vit_cell"))
fs = [float(x) for x in sp[1].split(",")] if sp and sp[1] else []
if len(fs) < 3: bad.append(f"cell reported {len(fs)} sector pulse factors")
elif max(abs(f - 1) for f in fs) < 0.01 or max(fs) - min(fs) < 0.01: bad.append(f"sector pulse not visible: {fs}")
# --- shut, quiet market: a hard zero
q = body("vit_quiet"); qt = text(q)
for k, want in (("pulseamp", 0.0), ("pulse", 1.0), ("fear", 0.0)):
    if num(q, k) != want: bad.append(f"quiet market: data-{k}={num(q, k)}, must be exactly {want}")
if "Volume closed" not in qt: bad.append("quiet market: mood block does not read 'Volume closed'")
if re.search(r"Fear \d", qt): bad.append("quiet market: a Fear reading is shown with no VIX")
if not re.search(r"no volume reading \(closed\)", qt): bad.append("quiet market: help does not say there is no volume reading")
qs = re.search(r'id="cell"[^>]*data-spulse="([^"]*)"', body("vit_cellq"))
if not qs or not qs[1] or any(float(x) != 1.0 for x in qs[1].split(",")): bad.append(f"quiet market: sector halos still move: {qs and qs[1]}")
if bad: print("✘ browser-check vitals: " + "; ".join(bad)); sys.exit(1)
print(f"✓ browser-check vitals: VIX {vix} -> fear {fear} ('{word}'), volume '{vw}' -> pulse amplitude {amp} (>=2%), sector factors {min(fs):.3f}..{max(fs):.3f}; quiet market exactly 0/1/0 and 'Volume closed'")
EOF


# ---- replay scrubber: #scrub=<frac> goes through the SAME Mood.scrubPos() a real pointer drag
# calls (see index.html) — a headless dump-dom cannot drag, so this exercises the identical
# function and wiring the drag handler uses, at three fractions including both edges ----
for FRAC in 0 0.5 1; do
  shoot 390,844 "http://127.0.0.1:8766/#day=$D_LAST&scrub=$FRAC" "$T/scrub_$FRAC"
done
shoot 390,844 "http://127.0.0.1:8766/.quiet-check/#day=$D_LAST&scrub=0.5" "$T/scrub_quiet"
python3 - "$T" "$D_LAST" <<'EOF' || RC=1
import json, re, sys
t, date = sys.argv[1], sys.argv[2]
mk = json.load(open("data/market.json"))
ix = [i for i in mk["indexes"] if i["key"] == "sp500"][0]
S = [x for x in ix["sessions"] if x["date"] == date][0]
nbars = len(S["bars"])
bad = []
for frac in ("0", "0.5", "1"):
    want = min(max(round(float(frac) * (nbars - 1)), 0), nbars - 1)
    dom = open(f"{t}/scrub_{frac}.html").read()
    m = re.search(r'id="track"[^>]*aria-valuenow="(\d+)"', dom)
    pos_m = re.search(r'id="clock"[^>]*>([^<]*)<', dom)
    want_pct = round(want / (nbars - 1) * 100)
    if not m: bad.append(f"scrub={frac}: track aria-valuenow not reported"); continue
    if abs(int(m[1]) - want_pct) > 1: bad.append(f"scrub={frac}: track at {m[1]}%, want ~{want_pct}% (bar {want} of {nbars})")
# the fill and handle wear the mood colour (inline --mood on the track, and the CSS reads it), the
# handle's glow is driven by the heartbeat (--beat), a faint sparkline of the day sits behind the
# track (one point per bar, not flat), and the clock rides INSIDE the track next to the handle
lefts = []
for frac in ("0", "0.5", "1"):
    dom = open(f"{t}/scrub_{frac}.html").read()
    tm = re.search(r'id="track"[^>]*style="([^"]*)"', dom)
    if not tm or not re.search(r"--mood: ?#[0-9a-f]{6}", tm[1]): bad.append(f"scrub={frac}: track carries no mood colour ({tm and tm[1]})")
    if not re.search(r"\.track i \{[^}]*background: var\(--mood\)", dom) or not re.search(r"\.track b \{[^}]*background: var\(--mood\)", dom): bad.append("fill/handle CSS is not tinted by --mood")
    if not re.search(r"\.track b \{[^}]*box-shadow:[^;]*var\(--beat\)", dom): bad.append("handle glow is not driven by --beat")
    bm = re.search(r"--beat: ?([\d.]+)", tm[1]) if tm else None
    if not bm or not 0 <= float(bm[1]) <= 1: bad.append(f"scrub={frac}: no --beat in 0..1")
    pts = re.search(r'id="sparkLine" points="([^"]*)"', dom)
    ys = [float(q.split(",")[1]) for q in pts[1].split()] if pts else []
    if len(ys) != nbars: bad.append(f"scrub={frac}: sparkline has {len(ys)} points, the day has {nbars} bars")
    elif max(ys) - min(ys) < 5: bad.append("sparkline is flat")
    cm = re.search(r'<div class="track" id="track".*?<span class="clock num" id="clock" style="left: ?([\d.]+)px', dom, re.S)
    if not cm: bad.append(f"scrub={frac}: the clock is not placed inside the track by the handle")
    else: lefts.append(float(cm[1]))
if len(lefts) == 3 and not (lefts[0] < lefts[1] < lefts[2]): bad.append(f"clock does not travel with the handle: {lefts}")
qd = open(f"{t}/scrub_quiet.html").read()
qb = re.search(r"--beat: ?([\d.]+)", (re.search(r'id="track"[^>]*style="([^"]*)"', qd) or [0, ""])[1])
if not qb or float(qb[1]) != 0: bad.append(f"quiet market: handle glow --beat={qb and qb[1]}, must be exactly 0")
if bad: print("✘ browser-check scrub: " + "; ".join(bad)); sys.exit(1)
print(f"✓ browser-check scrub: #scrub=0/0.5/1 land on the expected bars (of {nbars}); mood tint, breathing glow, {nbars}-point sparkline, clock at handle {lefts}")
EOF

exit $RC
