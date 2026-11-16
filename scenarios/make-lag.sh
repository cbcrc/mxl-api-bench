#!/bin/bash
# Head-3 variants of 08 (lines) and 11 (copy): lane B waits on each new grain with a
# plain blocking read (b4), then reads and touches cursor-4 = the grain 3 behind it (b4l).
set -eu
cd "$(dirname "$0")"
for pair in "08-transit-local-lines:12-transit-local-lines-lag3:lines" "11-transit-local-copy:13-transit-local-copy-lag3:copy"; do
  IFS=: read -r src dst touch <<< "${pair}"
  jq --arg name "${dst}" --arg touch "${touch}" '
    .name as $orig | .name = $name
    | .description = "Local transit, " + $touch + ", head-3. Same as " + $orig + " except lane B: b4 blocks on each new grain without touching it, then b4l reads and touches the grain three behind it (cursor-4 after b4 advanced), so the measured read is of a grain that three newer writes have gone over. transit_ms is ~3 frames by construction; touch_ms is the measure."
    | .lanes.B |= (map(
        if .id == "b4" then
          [ (.args |= del(.verify_stamp, .touch_payload)
             | .note = "waiter: blocks until the next grain commits, so the lag stays fixed at 3 grains"),
            { "id": "b4l", "call": "mxlFlowReaderGetGrain",
              "args": { "reader": "R", "index": { "mode": "cursor", "offset": -4 },
                        "timeout_ns": 2000000000, "verify_stamp": true, "touch_payload": $touch },
              "note": "cursor-4 after b4 advanced = head-3; already committed, so it does not block" } ]
        else [.] end) | add)
  ' "${src}.json" > "${dst}.json"
  echo "${dst}: $(jq -c '[.lanes.B[] | {id, index: .args.index, touch: .args.touch_payload, verify: .args.verify_stamp, to: .args.to, times: .args.times}]' "${dst}.json")"
done
