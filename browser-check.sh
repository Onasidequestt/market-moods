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
python3 -m http.server 8766 --bind 127.0.0.1 >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
sleep 1
ln -s "$T/nodata" ./.nodata-check 2>/dev/null; ln -s "$T/nofs" ./.nofs-check 2>/dev/null; ln -s "$T/nocomp" ./.nocomp-check 2>/dev/null
trap 'kill $SRV 2>/dev/null; rm -rf "$T"; rm -f ./.nodata-check ./.nofs-check ./.nocomp-check' EXIT
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
if not sk or int(sk[1]) != 50: bad.append(f"lamp: {sk and sk[1]} specks in the S&P 500 blob, want its 50 biggest companies")
# ...and really painted: on an up day the S&P 500's wax is green, so warm (red/amber) pixels inside
# its core are the falling companies' specks (on a down day: green pixels in red wax are the rising
# ones). The page's own count above cannot prove that.
sp_up = len(pcts) == 4 and pcts[1].startswith("+")
core = re.search(r'id="cell"[^>]*data-core="(\d+),(\d+),(\d+)"', okd)
im = Image.open(f"{t}/ok.png").convert("RGB"); W, H = im.size; sc = H / int(size.split(",")[1]); px = im.load(); warm = 0
if core:
    kx, ky, kr = (int(v) * sc for v in core.groups())
    for y in range(int(ky - kr), int(ky + kr)):
        for x in range(int(kx - kr), int(kx + kr)):
            if 0 <= x < W and 0 <= y < H and math.hypot(x - kx, y - ky) < kr * 0.85:
                r_, g_, b_ = px[x, y]
                if (r_ > 150 and r_ - g_ > 60) if sp_up else (g_ > 150 and g_ - r_ > 60): warm += 1
if warm < 12 * sc * sc: bad.append(f"lamp: {warm} against-colour pixels in the S&P 500 core: the companies' specks are not painted")
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

exit $RC
