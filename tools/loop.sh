#!/bin/sh
# usage: loop.sh <workflow-file> <period-seconds> <market|econ> <step command...>
# Why this exists: GitHub's schedule trigger is best-effort and was measured firing ~3 of ~49 times a
# weekday here (Oct 1: 3 runs, the first at 18:43Z), so "every 10 minutes" was really every few hours.
# A scheduled run now only STARTS a chain: this job runs the step on a clock for up to ~50 minutes, then
# starts the next link itself with workflow_dispatch (the one event GITHUB_TOKEN may trigger). The cron
# stays as the bootstrap. market = loop only while NYSE is open; econ = while the futures trade (Sun 18:00-Fri 17:00 ET).
# LOOP_FORCE=1 (manual test): two short rounds even when closed, no chaining. LOOP_FORCE=chain: one round, then really
# start the next link (proves the dispatch permission; the next link sees a closed market and stops).
# LOOP_WAKE="a.yml b.yml" (11-10): while NYSE is open, each round starts those workflows if they have no live run.
# The market chains die at every close and waited for the cron to restart them: measured 11-03..11-10, its first
# fire came 19:48-20:26Z, five hours after the open. The economy chain runs almost round the clock, so it wakes them.
# A failed round still never kills the chain, but the run now ends RED (11-10: a week of failed rounds sat behind green runs).
wf="$1"; period="$2"; when="$3"; shift 3
case "$when" in market|econ) ;; *) echo "::error::loop.sh: mode must be market or econ, got '$when'"; exit 2;; esac
end=$(( $(date +%s) + 3000 ))     # one link lasts ~50 min (job cap is 6 h; a gap between links is seconds)
n=0; bad=0
wake() {
  [ -n "$LOOP_WAKE" ] && [ -z "$LOOP_FORCE" ] && python3 fetch.py --market-open || return 0
  for w in $LOOP_WAKE; do
    live=$(gh run list -w "$w" -L 5 --json status --jq '[.[]|select(.status!="completed")]|length') || continue   # cannot tell: do not pile runs up
    [ "$live" = 0 ] || continue
    echo "wake: $w has no live run, starting it"; gh workflow run "$w" || echo "::warning::wake: could not start $w"
  done
}
while :; do
  t0=$(date +%s)
  if [ -z "$LOOP_FORCE" ] && ! python3 fetch.py --$when-open; then
    [ "$n" = 0 ] && echo "market closed: nothing to do"; break      # closed: no round, no chain
  fi
  wake
  "$@" || { echo "::error::round failed: $*"; bad=$((bad + 1)); }; n=$((n + 1))   # a bad round never kills the chain
  [ "$LOOP_FORCE" = chain ] && { echo "chain test: starting the next link"; gh workflow run "$wf" && exit 0; echo "::error::dispatch failed"; exit 1; }
  [ -n "$LOOP_FORCE" ] && [ "$n" -ge 2 ] && { echo "forced test: $n rounds, not chaining"; break; }
  left=$(( end - $(date +%s) ))
  [ "$left" -lt "$period" ] && break
  s=$(( period - ($(date +%s) - t0) )); [ "$s" -gt 0 ] && sleep "$s"
done
if [ -z "$LOOP_FORCE" ] && python3 fetch.py --$when-open; then
  echo "next link: $wf"; gh workflow run "$wf" || echo "::error::could not start the next link ($wf)"
fi
[ "$bad" = 0 ] || { echo "::error::$bad of $n rounds failed"; exit 1; }
