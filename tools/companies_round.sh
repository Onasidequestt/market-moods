#!/bin/sh
# one companies round. Each index is isolated (a failure keeps THAT index's last file), but a failure is
# no longer swallowed: the good files are committed, then the round exits non-zero so the run shows red.
# russell is expected to fail (no free source, see HANDOFF) and is not counted.
bad=""
for k in sp500 dow nasdaq; do python3 fetch.py --companies $k || bad="$bad $k"; done
python3 fetch.py --companies russell >/dev/null 2>&1 || echo "russell: no free source (expected)"
node check.js || bad="$bad check.js"
if [ -z "$bad" ]; then
  f="data/companies.json data/companies-dow.json data/companies-nasdaq.json"
  [ -f data/companies-russell.json ] && f="$f data/companies-russell.json"
  tools/commit_data.sh "data: companies" $f
else
  echo "::error::companies round failed for:$bad"
  # ship whichever indexes did refresh
  f=""; for k in sp500 dow nasdaq; do case "$bad" in *$k*) ;; *) [ $k = sp500 ] && f="$f data/companies.json" || f="$f data/companies-$k.json";; esac; done
  [ -n "$f" ] && node check.js >/dev/null 2>&1 && tools/commit_data.sh "data: companies (partial)" $f
  exit 1
fi
