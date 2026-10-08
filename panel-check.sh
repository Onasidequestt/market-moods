#!/bin/sh
# The details panel in REAL Chromium, driven by real mouse clicks (Chrome DevTools protocol), phone 390 and desktop 1440:
#  1. index: click the Dow blob -> the panel opens with the Dow's real name + symbol from data/market.json, a move with an
#     arrow AND a sign, focus inside it, a 48px close button; desktop = 360px at the right, phone = bottom sheet <= 60%
#  2. "Look inside" reaches the cell (the old openCell); a click on a company blob there opens the panel with THAT company's
#     real name (from data/companies.json); Esc closes and returns focus to what opened it; a click outside closes it
#     without also hiding the chrome
#  3. an economy blob on the front page opens a panel with its group name; its "Look inside" navigates to economy.html#g=<key>
#  4. economy.html: group blob -> panel (real group name) -> Look inside -> a member blob -> panel with the member's real name,
#     unit, frequency, and a year-on-year that is "—" (never 0) when the file has none
#  5. the panel markup/CSS/JS block is byte-identical in both pages (one shared component, no per-page drift)
# Screenshots with the panel open go to shots/panel/.   usage: sh panel-check.sh     (serves this folder on 127.0.0.1:8769)
cd "$(dirname "$0")" || exit 2
B="$HOME/.cache/puppeteer/chrome-headless-shell/mac_arm-152.0.7977.42/chrome-headless-shell-mac-arm64/chrome-headless-shell"
[ -x "$B" ] || B="$HOME/Library/Caches/ms-playwright/chromium_headless_shell-1148/chrome-mac/headless_shell"   # 10-07: the puppeteer cache was cleaned off the disk; Playwright's shell is the same binary
[ -x "$B" ] || { echo "✘ panel-check: chrome-headless-shell not found"; exit 2; }
mkdir -p shots/panel
python3 -m http.server 8769 --bind 127.0.0.1 >/dev/null 2>&1 & SRV=$!
P=$(mktemp -d)
"$B" --headless --user-data-dir="$P" --use-angle=swiftshader --enable-unsafe-swiftshader --remote-debugging-port=9339 --remote-allow-origins='*' \
  --hide-scrollbars about:blank >/dev/null 2>&1 & CH=$!
trap 'kill $SRV $CH 2>/dev/null; rm -rf "$P"' EXIT
sleep 2
python3 - "$(pwd)" <<'EOP'
import json, re, sys, time, urllib.request, websocket
root = sys.argv[1]
tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9339/json"))
ws = websocket.create_connection([t for t in tabs if t["type"] == "page"][0]["webSocketDebuggerUrl"], timeout=30)
_id = 0; urls = []
def send(method, **params):
    global _id; _id += 1; ws.send(json.dumps({"id": _id, "method": method, "params": params}))
    while True:
        m = json.loads(ws.recv())
        if m.get("method") == "Page.frameNavigated" and not m["params"]["frame"].get("parentId"): urls.append(m["params"]["frame"]["url"] + m["params"]["frame"].get("urlFragment", ""))
        if m.get("id") == _id: return m.get("result", {})
def ev(expr):
    r = send("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
    return r.get("result", {}).get("value")
def until(expr, secs=15):
    end = time.time() + secs
    while time.time() < end:
        v = ev(expr)
        if v: return v
        time.sleep(0.15)
    return None
def click(x, y):
    for t in ("mouseMoved", "mousePressed", "mouseReleased"):
        send("Input.dispatchMouseEvent", type=t, x=x, y=y, button="left", clickCount=1)
def key(k, code):
    for t in ("keyDown", "keyUp"): send("Input.dispatchKeyEvent", type=t, key=k, code=code, windowsVirtualKeyCode=27)
def shot(name):
    time.sleep(0.8)
    import base64
    open(f"{root}/shots/panel/{name}.png", "wb").write(base64.b64decode(send("Page.captureScreenshot", format="png")["data"]))
send("Page.enable"); bad = []
def ok(c, msg):
    print(("✓" if c else "✘") + " panel-check " + msg)
    if not c: bad.append(msg)
mk = json.load(open("data/market.json")); co = {c["s"]: c["n"] for c in json.load(open("data/companies.json"))["companies"]}
ec = json.load(open("data/economy.json")); gs = [g for g in ec["groups"] if g.get("members")]
DLAST = json.load(open("data/companies.json"))["sessions"][-1]["date"]   # a day the company file covers (as browser-check.sh does)
DOW = [i for i in mk["indexes"] if i["key"] == "dow"][0]
PANEL = "(()=>{const p=document.getElementById('panel');return p&&p.classList.contains('open')})()"
TXT = lambda i: f"document.getElementById('{i}').textContent"
def open_wait(title):  # the panel is open and shows this exact real name
    return until(f"{PANEL} && {TXT('pTitle')} === {json.dumps(title)}", 6)
ARROW = re.compile(r"^(▲ \+|▼ −|▬ \+?)\d")
for W, H, tag in ((1440, 900, "desktop"), (390, 844, "phone")):
    send("Emulation.setDeviceMetricsOverride", width=W, height=H, deviceScaleFactor=1, mobile=False)
    t = f"{tag}@{W}"
    # ---- 1. index blob -> panel
    send("Page.navigate", url="about:blank"); time.sleep(0.3); send("Page.navigate", url="http://127.0.0.1:8769/index.html#day=" + DLAST + "&at=12:10")
    ok(until("window.__mm && __mm.mode !== 'none' && __mm.blobXY('dow')"), f"{t}: front page drew the Dow blob")
    for _ in range(3):   # the blob drifts: re-read where it is, click, and look again
        xy = ev("__mm.blobXY('dow')"); click(xy["x"], xy["y"])
        if open_wait(DOW["name"]): break
    ok(open_wait(DOW["name"]), f"{t}: clicking the Dow blob opens the panel titled '{DOW['name']}' (from market.json)")
    ok(ev(TXT("pSym")) == DOW["symbol"], f"{t}: symbol is {DOW['symbol']}")
    mv = ev(TXT("pMove")); ok(bool(ARROW.match(mv or "")), f"{t}: move carries an arrow and a sign, not colour only ({mv})")
    ok(re.match(r"^(Up|Down|Flat) ", ev(TXT("pMoveSub")) or "") is not None, f"{t}: move is also said in words ({ev(TXT('pMoveSub'))})")
    ok(ev("document.activeElement && document.activeElement.id") == "pClose", f"{t}: focus moved into the panel")
    until("(()=>{const a=document.getElementById('panel').getBoundingClientRect();return a.right<=innerWidth+1&&a.bottom<=innerHeight+1})()", 8)   # the slide-in finished
    r = ev("(()=>{const a=document.getElementById('panel').getBoundingClientRect(),b=document.getElementById('pClose').getBoundingClientRect();return {l:a.left,t:a.top,w:a.width,h:a.height,r:a.right,b:a.bottom,cw:b.width,ch:b.height}})()")
    ok(r["cw"] >= 44 and r["ch"] >= 44, f"{t}: close button {r['cw']:.0f}x{r['ch']:.0f} (>= 44)")
    if W >= 700: ok(abs(r["w"] - 360) < 2 and abs(r["r"] - W) < 2, f"{t}: right-hand panel 360px wide (w={r['w']:.0f}, right={r['r']:.0f})")
    else: ok(r["h"] <= H * 0.6 + 1 and abs(r["b"] - H) < 2 and r["w"] >= W - 1, f"{t}: bottom sheet at most 60% high (h={r['h']:.0f} of {H})")
    rows = ev("[...document.querySelectorAll('#pRows dd')].map(d=>d.textContent)")
    ok(len(rows) >= 4 and "0" != rows[0], f"{t}: rows drawn from the data ({rows[:2]})")
    ok(ev("document.getElementById('pLook').hidden") is False, f"{t}: Look inside shown for an index with a cell")
    shot(f"index_{tag}_{W}")
    # ---- 2. Look inside -> cell; company blob -> panel
    ev("document.getElementById('pLook').click()")
    ok(until("__mm.inCell === true") and ev(PANEL) is False, f"{t}: Look inside reaches the cell and closes the panel")
    node = until("(()=>{const n=[...__mm.cellNodes.values()].filter(n=>n.dx!=null&&n.dy!=null&&n.r>3).sort((a,b)=>b.r-a.r)[0];return n&&{s:n.s,x:n.dx,y:n.dy}})()")
    ok(bool(node), f"{t}: cell drew company blobs")
    if not node: print(ev("JSON.stringify([...__mm.cellNodes.values()].slice(0,3).map(n=>Object.keys(n)))"), ev("__mm.cellNodes.size")); continue
    click(node["x"], node["y"])
    ok(co.get(node["s"]) and open_wait(co[node["s"]]), f"{t}: clicking {node['s']} opens the panel titled '{co.get(node['s'])}' (from companies.json)")
    ok(ev("document.getElementById('tip')") is None, f"{t}: the floating tooltip is gone")
    shot(f"cell_{tag}_{W}")
    key(("Escape"), "Escape")
    ok(until(f"!{PANEL}", 3) is True, f"{t}: Esc closes the panel")
    # focus returns to what opened it: open from a focused button
    ev("document.getElementById('helpBtn').focus()")
    ev(f"document.getElementById('cell').dispatchEvent(new MouseEvent('click',{{clientX:{node['x']},clientY:{node['y']},bubbles:true}}))")
    ok(open_wait(co[node["s"]]), f"{t}: panel reopens")
    key("Escape", "Escape")
    ok(until("document.activeElement && document.activeElement.id === 'helpBtn'", 3), f"{t}: Esc returns focus to the opener")
    click(node["x"], node["y"]); open_wait(co[node["s"]])
    bx = 8 if W >= 700 else W - 20; by = 300 if W >= 700 else 200   # a spot outside the panel, away from every blob
    click(bx, by)
    ok(until(f"!{PANEL}", 3) is True, f"{t}: a click outside closes the panel")
    # ---- 3. economy blob on the front page
    if gs:
        send("Page.navigate", url="about:blank"); time.sleep(0.3); send("Page.navigate", url="http://127.0.0.1:8769/index.html#day=" + DLAST + "&at=12:10")
        g = None
        until("window.__mm && document.body.dataset.econ && document.body.dataset.econ !== 'stale' && __mm.blobXY('" + gs[0]["key"] + "')")
        g = gs[0]; xy = ev(f"__mm.blobXY('{g['key']}')")
        if xy:
            click(xy["x"], xy["y"])
            ok(open_wait(g["name"]), f"{t}: front-page economy blob opens the panel titled '{g['name']}'")
            bare = ev("document.body.classList.contains('bare')")
            n0 = len(urls); ev("document.getElementById('pLook').click()"); time.sleep(1.5); ev('1')   # drain the navigation event
            ok(any(u.endswith("economy.html#g=" + g["key"]) for u in urls[n0:]), f"{t}: its Look inside goes to economy.html#g={g['key']} (saw {urls[n0:]})")
        else: ok(False, f"{t}: no front-page blob for {gs[0]['key']}")
    # ---- 4. economy.html
    send("Page.navigate", url="about:blank"); time.sleep(0.3); send("Page.navigate", url="http://127.0.0.1:8769/economy.html")
    if not until("window.__em && __em.groupXY('" + gs[0]["key"] + "')"): ok(False, f"{t}: economy page drew a group blob"); continue
    g = gs[0]; xy = ev(f"__em.groupXY('{g['key']}')"); click(xy["x"], xy["y"])
    ok(open_wait(g["name"]), f"{t}: economy group blob opens the panel titled '{g['name']}'")
    shot(f"economy_{tag}_{W}")
    ev("document.getElementById('pLook').click()")
    ok(until("__em.inCell === true") and ev(PANEL) is False, f"{t}: economy Look inside reaches the group view")
    for m in g["members"][:2] + [x for x in g["members"] if x.get("yoy") is None][:1]:
        xy = until(f"__em.memberXY('{m['key']}')")
        if not xy: ok(False, f"{t}: member {m['key']} drawn"); continue
        click(xy["x"], xy["y"]); ok(open_wait(m["name"]), f"{t}: member blob opens the panel titled '{m['name']}'")
        rows = dict(zip(ev("[...document.querySelectorAll('#pRows dt')].map(d=>d.textContent)"), ev("[...document.querySelectorAll('#pRows dd')].map(d=>d.textContent)")))
        ok(rows.get("Unit") == m["unit"] and rows.get("Frequency") == m["freq"], f"{t}: {m['key']} unit '{m['unit']}' and frequency '{m['freq']}' shown")
        want = "—" if m.get("yoy") is None else ("+" if m["yoy"] >= 0 else "−") + f"{abs(m['yoy']):.2f}%"
        ok(rows.get("Year on year") == want, f"{t}: {m['key']} year on year is {want} (got {rows.get('Year on year')})")
        if m is g["members"][0]: shot(f"economy_member_{tag}_{W}")
        key("Escape", "Escape"); until(f"!{PANEL}", 3)
# ---- 5. one shared component
def block(f, a, b): return re.search(re.escape(a) + r".*?" + re.escape(b), open(f).read(), re.S)[0]
ok(block("index.html", "/* PANEL-CSS", "END PANEL-CSS */") == block("economy.html", "/* PANEL-CSS", "END PANEL-CSS */"), "panel CSS identical in both pages")
ok(block("index.html", "// PANEL-JS", "// END PANEL-JS") == block("economy.html", "// PANEL-JS", "// END PANEL-JS"), "panel JS identical in both pages")
ok(re.search(r'<aside class="panel".*?</aside>', open("index.html").read(), re.S)[0] == re.search(r'<aside class="panel".*?</aside>', open("economy.html").read(), re.S)[0], "panel markup identical in both pages")
print(("✘" if bad else "✓") + f" panel-check: {len(bad)} failed"); sys.exit(1 if bad else 0)
EOP
