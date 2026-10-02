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
  git pull -q --rebase --autostash && git push -q && { echo "pushed"; exit 0; }
  sleep $((i * 5))
done
echo "::error::could not push $msg after 4 tries"; exit 1
