#!/bin/sh
# one index round: fetch, check, commit (called by tools/loop.sh from fetch.yml)
python3 fetch.py && node check.js && tools/commit_data.sh "data:" data/market.json
