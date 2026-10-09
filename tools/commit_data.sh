#!/bin/sh
# usage: commit_data.sh "<message>" <data files...>
# Cutover to the client's own Cloudflare Pages project (when his domain goes live): (1) in GitHub repo settings swap the
# secrets CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID for his; (2) set CF_PAGES_PROJECT in the three workflows to his
# project name; (3) run one workflow by hand (workflow_dispatch) and read "deployed to Cloudflare Pages (<his project>)"
# in the log; (4) if the repo moves, change the `if: github.repository ==` guard in the three workflows. Half a cutover
# (new project, old token) fails loudly below rather than deploying to the wrong place.
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

# Mirror the page to the Cloudflare Pages preview (our own account, 2026-10-03). After the rebase the
# tree holds every workflow's latest data, so each deploy is the whole site as of now. Only the files the
# page loads go up: never HANDOFF, plans or client mail. A failed deploy warns; the data push already landed.
# ponytail: at most one deploy per job per 9 min (≈ one per round; ~160 on a busy weekday across the three
# jobs). The page copied up is whole: _headers rides along. Ceiling: Cloudflare's docs don't say whether direct uploads count against the Free plan's 500
# builds/month; if they do, deploys start failing early in the month. Upgrade path: one deploy workflow on
# a slower clock, or the client's own Cloudflare account on a paid plan.
# A deploy is expected as soon as either secret is set; then anything short of a deploy is an error (10-08: a missing
# or expired token used to exit 0 and leave the live site frozen behind a green run). Neither set = GitHub Pages only.
[ -n "$CLOUDFLARE_API_TOKEN$CF_PAGES_PROJECT" ] || { echo "no CLOUDFLARE_API_TOKEN and no CF_PAGES_PROJECT, skip Pages deploy"; exit 0; }
[ -n "$CLOUDFLARE_API_TOKEN" ] || { echo "::error::CF_PAGES_PROJECT is set but CLOUDFLARE_API_TOKEN is missing: no Pages deploy"; exit 1; }
[ -n "$CF_PAGES_PROJECT" ] || { echo "::error::CLOUDFLARE_API_TOKEN is set but CF_PAGES_PROJECT is not: refusing to guess the project"; exit 1; }
stamp="${RUNNER_TEMP:-/tmp}/mm_pages_deployed"
[ -f "$stamp" ] && [ $(( $(date +%s) - $(cat "$stamp") )) -lt 540 ] && { echo "deployed <9 min ago, skip"; exit 0; }
site=$(mktemp -d)
cp index.html economy.html mood.js _headers "$site"/ && cp -R data assets "$site"/ \
  && npx --yes wrangler@4 pages deploy "$site" --project-name="$CF_PAGES_PROJECT" \
       --branch=main --commit-dirty=true </dev/null \
  && { date +%s > "$stamp"; echo "deployed to Cloudflare Pages ($CF_PAGES_PROJECT)"; exit 0; }   # the stamp marks a deploy that LANDED: a failed one must not make the next job skip
echo "::error::Cloudflare Pages deploy to $CF_PAGES_PROJECT failed; the data push landed, the live site is behind"; exit 1
