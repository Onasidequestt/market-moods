#!/bin/sh
# The page in REAL Chromium (software WebGL) at phone and desktop width.
#  1. with data: status says live or replaying, four cards carry a % and a level,
#     the mood word is set, and the lamp drew coloured wax (not just the dark background)
#  2. without data: the honest "couldn't load" notice shows and NO wax is drawn
# usage: sh browser-check.sh     (serves this folder on 127.0.0.1:8766 while it runs)
cd "$(dirname "$0")" || exit 2
B="$HOME/.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.42/chrome-headless-shell-mac-arm64/chrome-headless-shell"
[ -x "$B" ] || { echo "✘ browser-check: chrome-headless-shell not found"; exit 2; }
T=$(mktemp -d); mkdir -p "$T/nodata"; cp index.html mood.js "$T/nodata/"
python3 -m http.server 8766 --bind 127.0.0.1 >/dev/null 2>&1 & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
sleep 1
ln -s "$T/nodata" ./.nodata-check 2>/dev/null
trap 'kill $SRV 2>/dev/null; rm -rf "$T"; rm -f ./.nodata-check' EXIT
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
  python3 - "$T" "$SIZE" <<'EOF' || RC=1
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
tags = re.findall(r'<span style="([^"]*)">(Dow|S&amp;P 500|Nasdaq|Russell)</span>', dom) + \
       [("", n) for n in re.findall(r'<span>(Dow|S&amp;P 500|Nasdaq|Russell)</span>', dom)]
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
if bad: print(f"✘ browser-check {size}: " + "; ".join(bad)); sys.exit(1)
print(f"✓ browser-check {size} (real Chromium): cards {pcts} · wax {w_ok}px · no-data notice ✓, wax {w_no}px · Wed 23 {dp}")
EOF
done
exit $RC
