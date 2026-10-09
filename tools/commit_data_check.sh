#!/bin/sh
# Self-check for commit_data.sh's Cloudflare Pages step, offline: a throwaway repo + bare remote, and a fake
# `npx` on PATH that records what it was asked to upload. Run: sh tools/commit_data_check.sh
here=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); fails=0
git init -q --bare "$t/remote.git" && git clone -q "$t/remote.git" "$t/w" 2>/dev/null
mkdir -p "$t/bin" "$t/w/data" "$t/w/assets"
cat > "$t/bin/npx" <<'EOF'
#!/bin/sh
for a; do case "$a" in /*) ls -R "$a" > "$NPX_LOG";; esac; done
[ -z "$NPX_FAIL" ]
EOF
chmod +x "$t/bin/npx"
cd "$t/w" && git config user.email t@t && git config user.name t
echo a > index.html; echo a > economy.html; echo a > mood.js; echo a > _headers; echo a > HANDOFF.md; echo 1 > data/market.json; echo a > assets/crest.png
git add -A && git commit -qm init && git push -q origin HEAD 2>/dev/null
run() { echo "$1" > data/market.json; PATH="$t/bin:$PATH" RUNNER_TEMP="$t" NPX_LOG="$t/log" sh "$here/commit_data.sh" test data/market.json; }
ok() { if eval "$2"; then echo "✓ $1"; else echo "✘ $1"; fails=$((fails+1)); fi; }

out=$(run 2); ok "no token, no project: pushes, skips deploy" 'echo "$out" | grep -q "skip Pages" && [ ! -f "$t/log" ]'
out=$(CF_PAGES_PROJECT=p run 2b); rc=$?; ok "project without token: ::error, exit 1" '[ $rc -eq 1 ] && echo "$out" | grep -q "::error::CF_PAGES_PROJECT is set"'
export CLOUDFLARE_API_TOKEN=x
out=$(run 2c); rc=$?; ok "token without project: ::error, exit 1, no guessed project" '[ $rc -eq 1 ] && echo "$out" | grep -q "::error::" && [ ! -f "$t/log" ]'
export CF_PAGES_PROJECT=market-moods-test
out=$(run 3); ok "token + project: deploys to that project" 'echo "$out" | grep -q "deployed to Cloudflare Pages (market-moods-test)"'
ok "uploads page + data + assets only, no HANDOFF" 'grep -q market.json "$t/log" && grep -q mood.js "$t/log" && grep -q crest.png "$t/log" && ! grep -q HANDOFF "$t/log"'
# 10-09: assets/ (the crest, a754903) was never added to the upload list, so Pages served index.html in its place.
# Every local file or folder the REAL pages load must be named on the cp line.
refs=$(grep -ohE '(src|href)="[^"#?]+|fetch\("[^"?]+' "$here/../index.html" "$here/../economy.html" | sed -E 's/^[^"]*"//; s#/.*##' | grep -v : | sort -u)
cpline=$(grep -E '^cp .*"\$site"' "$here/commit_data.sh"); missing=""
for r in $refs; do echo "$cpline" | grep -qw -- "$r" || missing="$missing $r"; done
ok "every file the real pages load is uploaded${missing:+ (missing:$missing)}" '[ -n "$refs" ] && [ -z "$missing" ]'
rm -f "$t/log"; out=$(run 4); ok "second deploy within 9 min skips" 'echo "$out" | grep -q "<9 min" && [ ! -f "$t/log" ]'
rm -f "$t/mm_pages_deployed"; out=$(NPX_FAIL=1 run 5); rc=$?
ok "failed deploy is an ::error and exits 1 (the run goes red, the data push stays)" '[ $rc -eq 1 ] && echo "$out" | grep -q "::error::Cloudflare Pages deploy"'
ok "data still reached the remote" '[ "$(git --git-dir="$t/remote.git" show HEAD:data/market.json)" = 5 ]'
out=$(run 6); ok "after a failed deploy the next call deploys again (no stamp from the failure)" 'echo "$out" | grep -q "deployed to Cloudflare Pages"'
rm -rf "$t"; [ $fails -eq 0 ] && echo "commit_data_check: all pass" || { echo "commit_data_check: $fails FAILED"; exit 1; }
