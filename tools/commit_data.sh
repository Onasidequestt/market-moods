#!/bin/sh
# usage: commit_data.sh "<message>" <data files...>
# Commit + push only when one of the files changed. Retries the rebase/push: the three data workflows
# push to the same branch on their own clocks and used to lose a race and drop the run's data.
msg="$1"; shift
git diff --quiet -- "$@" && { echo "no change"; exit 0; }
git config user.name "market-moods bot"
git config user.email "actions@users.noreply.github.com"
git add "$@"
git commit -q -m "$msg $(date -u +%FT%TZ)"
for i in 1 2 3 4; do
  git pull -q --rebase --autostash && git push -q && { echo "pushed"; pushed=1; break; }
  sleep $((i * 5))
done
[ -n "$pushed" ] || { echo "::error::could not push $msg after 4 tries"; exit 1; }

# Mirror the page to the Cloudflare Pages preview (SWITCHBOARD's account, 2026-10-03). After the rebase the
# tree holds every workflow's latest data, so each deploy is the whole site as of now. Only the files the
# page loads go up: never HANDOFF, plans or client mail. A failed deploy warns; the data push already landed.
# ponytail: at most one deploy per job per 9 min (≈ one per round; ~160 on a busy weekday across the three
# jobs). Ceiling: Cloudflare's docs don't say whether direct uploads count against the Free plan's 500
# builds/month; if they do, deploys start failing early in the month. Upgrade path: one deploy workflow on
# a slower clock, or the client's own Cloudflare account on a paid plan.
[ -n "$CLOUDFLARE_API_TOKEN" ] || { echo "no CLOUDFLARE_API_TOKEN, skip Pages deploy"; exit 0; }
stamp="${RUNNER_TEMP:-/tmp}/mm_pages_deployed"
[ -f "$stamp" ] && [ $(( $(date +%s) - $(cat "$stamp") )) -lt 540 ] && { echo "deployed <9 min ago, skip"; exit 0; }
date +%s > "$stamp"
site=$(mktemp -d)
cp index.html economy.html mood.js "$site"/ && cp -R data "$site"/ \
  && npx --yes wrangler@4 pages deploy "$site" --project-name="${CF_PAGES_PROJECT:-market-moods-preview}" \
       --branch=main --commit-dirty=true </dev/null \
  && echo "deployed to Cloudflare Pages" \
  || echo "::warning::Cloudflare Pages deploy failed; GitHub Pages still has the data"
exit 0
