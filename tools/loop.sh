#!/bin/sh
# usage: loop.sh <workflow-file> <period-seconds> <market|econ> <step command...>
# Why this exists: GitHub's schedule trigger is best-effort and was measured firing ~3 of ~49 times a
# weekday here (Oct 1: 3 runs, the first at 18:43Z), so "every 10 minutes" was really every few hours.
# A scheduled run now only STARTS a chain: this job runs the step on a clock for up to ~50 minutes, then
# starts the next link itself with workflow_dispatch (the one event GITHUB_TOKEN may trigger). The cron
# stays as the bootstrap. market = loop only while NYSE is open; econ = while the futures trade (Sun 18:00-Fri 17:00 ET).
# LOOP_FORCE=1 (manual test): two short rounds even when closed, no chaining. LOOP_FORCE=chain: one round, then really
# start the next link (proves the dispatch permission; the next link sees a closed market and stops).
wf="$1"; period="$2"; when="$3"; shift 3
case "$when" in market|econ) ;; *) echo "::error::loop.sh: mode must be market or econ, got '$when'"; exit 2;; esac
end=$(( $(date +%s) + 3000 ))     # one link lasts ~50 min (job cap is 6 h; a gap between links is seconds)
n=0
while :; do
  t0=$(date +%s)
  if [ -z "$LOOP_FORCE" ] && ! python3 fetch.py --$when-open; then
    [ "$n" = 0 ] && echo "market closed: nothing to do"; exit 0      # closed: no round, no chain
  fi
  "$@" || echo "::warning::round failed: $*"; n=$((n + 1))   # a bad round never kills the chain
  [ "$LOOP_FORCE" = chain ] && { echo "chain test: starting the next link"; gh workflow run "$wf" && exit 0; echo "::error::dispatch failed"; exit 1; }
  [ -n "$LOOP_FORCE" ] && [ "$n" -ge 2 ] && { echo "forced test: $n rounds, not chaining"; exit 0; }
  left=$(( end - $(date +%s) ))
  [ "$left" -lt "$period" ] && break
  s=$(( period - ($(date +%s) - t0) )); [ "$s" -gt 0 ] && sleep "$s"
done
[ -n "$LOOP_FORCE" ] && exit 0
if python3 fetch.py --$when-open; then
  echo "next link: $wf"; gh workflow run "$wf" || echo "::error::could not start the next link ($wf)"
fi
