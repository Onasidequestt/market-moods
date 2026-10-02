#!/bin/sh
python3 fetch.py --economy && node check.js --fresh && tools/commit_data.sh "data: economy" data/economy.json
