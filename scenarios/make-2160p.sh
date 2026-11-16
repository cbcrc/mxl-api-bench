#!/bin/bash
# 2160p variants of 08 (lines) and 11 (copy), regular and head-3 (same lane-B rewrite as make-lag.sh).
set -eu
cd "$(dirname "$0")"
to2160p='
  .description |= sub("1080p29.97"; "2160p29.97")
  | (.lanes.A[] | select(.id=="a1").args.flow_def) |= (fromjson
      | .label = "ABI Tester Transit 2160p"
      | .description = "2160p29.97 v210 transit-measurement flow written by the ABI tester"
      | .frame_width = 3840 | .frame_height = 2160
      | .components = [{"name":"Y","width":3840,"height":2160,"bit_depth":10},
                       {"name":"Cb","width":1920,"height":2160,"bit_depth":10},
                       {"name":"Cr","width":1920,"height":2160,"bit_depth":10}]
      | tojson)'
lag3='
  .description = "Local transit, " + $touch + ", 2160p, head-3. Same as " + .name + " except lane B: b4 blocks on each new grain without touching it, then b4l reads and touches the grain three behind it (cursor-4 after b4 advanced). Three newer 22 MB grains (66 MB) are written over it, more than one socket L3 (30 MB), so the read comes from DRAM. transit_ms is ~3 frames by construction; touch_ms is the measure."
  | .lanes.B |= (map(
      if .id == "b4" then
        [ (.args |= del(.verify_stamp, .touch_payload)
           | .note = "waiter: blocks until the next grain commits, so the lag stays fixed at 3 grains"),
          { "id": "b4l", "call": "mxlFlowReaderGetGrain",
            "args": { "reader": "R", "index": { "mode": "cursor", "offset": -4 },
                      "timeout_ns": 2000000000, "verify_stamp": true, "touch_payload": $touch },
            "note": "cursor-4 after b4 advanced = head-3; already committed, so it does not block" } ]
      else [.] end) | add)'
for spec in "08-transit-local-lines:lines:14-transit-local-lines-2160p:16-transit-local-lines-2160p-lag3" \
            "11-transit-local-copy:copy:15-transit-local-copy-2160p:17-transit-local-copy-2160p-lag3"; do
  IFS=: read -r src touch reg lag <<< "${spec}"
  jq --arg name "${reg}" "${to2160p} | .name = \$name" "${src}.json" > "${reg}.json"
  jq --arg name "${lag}" --arg touch "${touch}" "${lag3} | .name = \$name" "${reg}.json" > "${lag}.json"
  for f in "${reg}" "${lag}"; do
    echo "${f}: $(jq -r '(.lanes.A[]|select(.id=="a1").args.flow_def|fromjson|"\(.frame_width)x\(.frame_height)")' "${f}.json") B=$(jq -c '[.lanes.B[] | select(.call=="mxlFlowReaderGetGrain") | "\(.id):\(.args.index.mode)\(.args.index.offset // "")/\(.args.touch_payload // "-")"]' "${f}.json")"
  done
done
