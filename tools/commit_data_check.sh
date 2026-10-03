#!/bin/sh
# Self-check for commit_data.sh's Cloudflare Pages step, offline: a throwaway repo + bare remote, and a fake
# `npx` on PATH that records what it was asked to upload. Run: sh tools/commit_data_check.sh
here=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); fails=0
git init -q --bare "$t/remote.git" && git clone -q "$t/remote.git" "$t/w" 2>/dev/null
mkdir -p "$t/bin" "$t/w/data"
cat > "$t/bin/npx" <<'EOF'
#!/bin/sh
for a; do case "$a" in /*) ls -R "$a" > "$NPX_LOG";; esac; done
[ -z "$NPX_FAIL" ]
EOF
chmod +x "$t/bin/npx"
cd "$t/w" && git config user.email t@t && git config user.name t
echo a > index.html; echo a > economy.html; echo a > mood.js; echo a > HANDOFF.md; echo 1 > data/market.json
git add -A && git commit -qm init && git push -q origin HEAD 2>/dev/null
run() { echo "$1" > data/market.json; PATH="$t/bin:$PATH" RUNNER_TEMP="$t" NPX_LOG="$t/log" sh "$here/commit_data.sh" test data/market.json; }
ok() { if eval "$2"; then echo "✓ $1"; else echo "✘ $1"; fails=$((fails+1)); fi; }

out=$(run 2); ok "no token: pushes, skips deploy" 'echo "$out" | grep -q "skip Pages" && [ ! -f "$t/log" ]'
export CLOUDFLARE_API_TOKEN=x
out=$(run 3); ok "token: deploys" 'echo "$out" | grep -q "deployed to Cloudflare"'
ok "uploads page + data only, no HANDOFF" 'grep -q market.json "$t/log" && grep -q mood.js "$t/log" && ! grep -q HANDOFF "$t/log"'
rm -f "$t/log"; out=$(run 4); ok "second deploy within 9 min skips" 'echo "$out" | grep -q "<9 min" && [ ! -f "$t/log" ]'
rm -f "$t/mm_pages_deployed"; out=$(NPX_FAIL=1 run 5); rc=$?
ok "failed deploy warns, exits 0" '[ $rc -eq 0 ] && echo "$out" | grep -q "::warning::"'
ok "data still reached the remote" '[ "$(git --git-dir="$t/remote.git" show HEAD:data/market.json)" = 5 ]'
rm -rf "$t"; [ $fails -eq 0 ] && echo "commit_data_check: all pass" || { echo "commit_data_check: $fails FAILED"; exit 1; }
