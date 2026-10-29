#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CBC/Radio-Canada
# SPDX-License-Identifier: Apache-2.0
#
# Loads a scenario into a running bench, runs it, and fails unless every lane
# reaches the end of its steps and every call comes back ok. CI runs it against
# `docker compose up`; it works the same against a local stack:
#
#     ci/run-scenario.sh scenarios/01-video-write-read.json [base-url] [timeout-s]
set -euo pipefail

SCENARIO=$1
B=${2:-http://localhost:9607}
TIMEOUT=${3:-60}

for _ in $(seq 1 30); do curl -sf "$B/health" >/dev/null && break; sleep 1; done
curl -sf "$B/health"
echo

# Start from released handles, and count only this run's events: the server
# keeps both from whatever ran on it before.
curl -sf -X POST "$B/reset" >/dev/null
since=$(curl -sf "$B/log?since=0" | jq 'map(.seq) | max // 0')
curl -sf -X POST -H 'Content-Type: application/json' --data-binary @"$SCENARIO" "$B/scenario" >/dev/null
curl -sf -X POST "$B/run" >/dev/null

# A lane's `next` moves past a step before that step's event is in the log, so
# finished also waits for the log to stop growing between two polls.
finished=false
logged=-1
for _ in $(seq 1 "$TIMEOUT"); do
  sleep 1
  done_lanes=$(curl -sf "$B/state" | jq '[.lanes[] | .next == (.steps | length)] | all')
  previous=$logged
  logged=$(curl -sf "$B/log?since=$since" | jq length)
  if [ "$done_lanes" = true ] && [ "$logged" -eq "$previous" ]; then finished=true; break; fi
done

log=$(curl -sf "$B/log?since=$since")
jq -r '.[] | [.seq, .lane, .call, (.status // "-"), .ok] | @tsv' <<<"$log"

failed=$(jq '[.[] | select(.ok != true)] | length' <<<"$log")
if [ "$finished" != true ]; then
  echo "FAIL: $SCENARIO did not finish within ${TIMEOUT}s" >&2
  curl -sf "$B/state" | jq -c '[.lanes[] | {next, steps: (.steps | length)}]' >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "FAIL: $failed call(s) in $SCENARIO did not return ok" >&2
  exit 1
fi
echo "PASS: $SCENARIO, $(jq length <<<"$log") events, all ok"
