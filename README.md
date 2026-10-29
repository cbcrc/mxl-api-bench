<!--
SPDX-FileCopyrightText: 2026 CBC/Radio-Canada
SPDX-License-Identifier: CC-BY-4.0
-->

# MXL API Bench

A bench instrument for the [MXL SDK](https://github.com/dmf-mxl/mxl), built at the commit pinned in
[`MXL_COMMIT`](./MXL_COMMIT). It exposes all 42 MXL C ABI calls as queueable steps across parallel
lanes, runs them at the pace you choose — paced to each grain's media clock (real time), spread out
with explicit delays, or stepped one call at a time — and measures OTS-derived latency and
end-to-end propagation delay. Image `mxl-api-bench:latest`, UI at http://localhost:9607.

A C++ backend links `libmxl` directly and serves both the REST API and a React frontend on one
port. Nothing is simulated: every row in the event log is one real call through the C ABI, with
its own `duration_us`.

**What it is for.** Answering questions about the SDK that the headers do not answer — what a
status code actually means, what a call does at a boundary, which of two recovery strategies
works. The bundled scenarios are the accumulated answers; see
[`FINDINGS.md`](./FINDINGS.md).

The cross-NUMA transit study run with it is in [`numa-guide.md`](./numa-guide.md) (method),
[`numa-results.md`](./numa-results.md) (data) and
[the executive summary](./executive_summary_cross_numa_cost_of_mxl_grain_transit.md).

## The MXL domain

`docker-compose.yml` brings its own domain: a RAM-backed (`tmpfs`) volume, seeded with
[`domain_def.json`](./domain_def.json) by a `busybox` `domain-init` service. That service stays
running on purpose: the tmpfs is wiped when its last container exits, so it holds the mount open,
and the bench waits for its healthcheck before starting. The domain lives only as long as the stack;
`docker compose down` wipes its contents. Another container joins it by mounting the `mxl-api-bench_mxl-domain`
volume at its own domain path.

## Run it

```sh
cd ~/mxl-api-bench
docker compose up --build -d
```

Then open **http://localhost:9607**. The first build compiles the MXL SDK from source (vcpkg
dependencies included), so a cold build takes a while; later builds reuse the cached layers.

## The MXL SDK version

[`MXL_COMMIT`](./MXL_COMMIT) holds the 40-character `dmf-mxl/mxl` commit the image builds. The
Dockerfile copies it in after the toolchain layers, fetches that one commit and builds `libmxl` and
`mxl-info`. To move to another SDK version, change the sha and rebuild; only the layers from the
fetch onward are redone. The library is installed under its SONAME, so a minor version bump needs no
Dockerfile edit.

## CI and publishing

[`.github/workflows/build-test-publish.yml`](./.github/workflows/build-test-publish.yml) runs on
every pull request and on every push to `main`. It builds the image, brings up
`docker-compose.yml`, and runs scenario `01-video-write-read` through
[`ci/run-scenario.sh`](./ci/run-scenario.sh), which fails unless every lane finishes and every
call returns ok. The same script works against a local stack:

```sh
docker compose up -d && ci/run-scenario.sh scenarios/01-video-write-read.json
```

On `main` the job then pushes `ghcr.io/cbcrc/mxl-api-bench` with SBOM and provenance attached,
tagged like the mxl-hands-on images — `api-bench-<repo short sha>-mxl-<MXL_COMMIT short sha>` and
`latest` — and checks that the SBOM landed:

```sh
docker buildx imagetools inspect ghcr.io/cbcrc/mxl-api-bench:latest --format '{{ json .SBOM }}' | head -c 500
```

## Using it

1. **Domains** — the panel lists every domain found under `MXL_DOMAIN_ROOT`, with its buffer depth.
2. **Builder** — pick a call from the 42-entry catalog, fill the generated form, queue it on a
   lane. Lanes run in parallel threads and never share handles.
3. **Transport** — Run / Pause / Step per lane / Reset, with a delay scale that multiplies every
   `delay_before_ms` (it does **not** affect `pace`d steps, which aim at their grain's own OTS).
4. **Console and timing panel** — every call as it happens, and the derived latency table:
   write OTS, write wall clock, read wall clock, `age_ms`, `transit_ms`.

Scenarios saved from the UI land in `scenarios/` in the working tree, because compose
bind-mounts `scenarios` over `/app/scenarios`. A new scenario file is picked up without a
rebuild.

## Bundled scenarios

| File | What it demonstrates |
|---|---|
| `01-video-write-read` | Baseline discrete round trip, one grain per second |
| `02-audio-write-read` | Baseline continuous round trip. A blocking read that **wakes on the commit** (~500 ms into a 3 s deadline) next to one that expires (500 ms of 500 ms) — both return through `waited_ms`, and a timeout never surfaces as `MXL_ERR_TIMEOUT` |
| `03-late-reader` | Both edges of the ring on one reader: `MXL_ERR_OUT_OF_RANGE_TOO_LATE` behind it, `MXL_ERR_OUT_OF_RANGE_TOO_EARLY` ahead |
| `04-writer-conflict` | That there is **no** writer exclusion: `MXL_ERR_CONFLICT` is declared and never returned, and `mxlIsFlowActive` means "someone holds this flow open". Releasing the *last* writer deletes the flow |
| `05-slice-write` | One `OpenGrain`, four partial commits at 270 / 540 / 810 / 1080 slices; `headIndex` advances on the **first** partial commit |
| `06-flow-invalid` | A stale reader returns `MXL_STATUS_OK` with **stale data**; `MXL_ERR_FLOW_INVALID` appears only on the `TOO_EARLY` path. Recovery needs every reader reference dropped — **not** a new instance |
| `07-sync-group` | A synchronization group waits for its **slowest** member — it is a rendezvous, not a realigner. Video + audio, audio silent for 4 s and video then 2 frames late; the wait grows by exactly the laggard's delay. **Found an SDK bug:** a group with more than one member stops synchronizing after its first successful wait and returns `MXL_STATUS_OK` instantly |

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `MXL_DOMAIN_ROOT` | `/mxl-domain` | Root scanned for domains (any directory containing `domain_def.json`) |
| `SCENARIO_DIR` | `/app/scenarios` | Where scenarios are listed from and saved to |
| `FRONTEND_DIST` | `/app/frontend/dist` | Built React app; if absent the server runs API-only |
| `MXL_API_BENCH_LANES` | `8` | Lane pool size (`A`..`H`) |
| `MXL_API_BENCH_LOG_FILE` | — | Mirror every event to an NDJSON file. Unset by default, so nothing is written to disk at all. Compose bind-mounts `logs` to `/app/logs` and carries a commented-out `MXL_API_BENCH_LOG_FILE=/app/logs/events.ndjson` — uncomment to keep a run. Appends rather than truncates; a second run of one process writes `events.2.ndjson`, the counter before the extension so `read_json_auto('*.ndjson')` still finds every run |
| `MXL_API_BENCH_LOG_MAX_BYTES` | unlimited | Cap the log; older events are evicted and `/log` answers `410` with a cursor to re-sync |
| `MXL_LOG_LEVEL` | — | The SDK's own spdlog level, e.g. `debug`. Invaluable when the library, not the tool, is the suspect |

The domain the *instances* open is a command argument, not an environment variable:
`mxl-api-bench [alias=]<path> ...`, defaulting to `default=/mxl-domain` in the entrypoint. Override
it with a compose `command:` to bind several aliased domains at once.

## Native development loop

Docker is only needed to ship it. A native build needs an MXL SDK checkout at the pinned commit,
built with its own CMake preset. `backend/CMakeLists.txt` looks for it in `./dmf-mxl` (gitignored);
pass `-DMXL_ROOT=/path/to/mxl` to use one elsewhere, and `-DMXL_PRESET=` if the build directory is
not `Linux-Clang-Release` (or `Darwin-Clang-Release` on macOS).

```sh
git clone https://github.com/dmf-mxl/mxl.git dmf-mxl && git -C dmf-mxl checkout "$(cat MXL_COMMIT)"
# build dmf-mxl with its own preset (see its README), then, against the host tmpfs domain:
export MXL_DOMAIN=/Volumes/mxl/domain_1
cd backend && cmake -B build && cmake --build build && ./build/mxl-api-bench $MXL_DOMAIN
cd ../frontend && npm run dev          # Vite on 9707, proxying the API to 9600
```

`source dev.sh` adds the curl helpers used throughout the findings.

## API

| Route | Purpose |
|---|---|
| `GET /health`, `GET /domains`, `GET /abi-calls` | SDK version, domain scan, the 42-call catalog with parameter schemas |
| `POST /call` | Run one call ad hoc. Needs `"domain"` spelled out on `mxlCreateInstance` |
| `GET/POST /scenario`, `GET/POST /scenarios/<name>` | The loaded scenario, and the files on disk |
| `POST /run`, `/pause`, `/step`, `/reset` | Transport. All four answer with a full `/state` |
| `GET /state`, `GET /log?since=<seq>` | Lanes, handles, and the event log (a bare array; `410` carries a re-sync cursor) |

## Known SDK issues these scenarios surfaced

- **A synchronization group with two or more members stops synchronizing after its first successful
  `WaitForDataAt`**, returning `MXL_STATUS_OK` in ~0.0003 ms thereafter
  (`FlowSynchronizationGroup.cpp:112` misuses `forward_list::splice_after`). Workaround: a fresh
  group per wait, or one member per group. Single-member groups are unaffected. `07-sync-group`
  demonstrates both the failure and the workaround side by side.
- `MXL_ERR_CONFLICT` is declared and never returned; there is no writer exclusion (`04`).
- Releasing the **last** writer deletes the flow directory (`04`, `06`).
- A stale reader returns `MXL_STATUS_OK` with stale data; `MXL_ERR_FLOW_INVALID` only ever appears
  on the `TOO_EARLY` path (`06`).

## A caveat worth knowing

The container runs as **root**, so flows it creates are root-owned in the domain. A container
killed with `docker stop` leaves its flows behind as *stale* — the state
`mxlGarbageCollectFlows` exists to clean up, and the tool can call it on itself.
The same applies to anything it writes into `logs`: the files are root-owned.
That directory is committed (with a `.gitignore`) precisely so Docker does not create it
as root — you own the directory, so you can still delete what the container leaves in it.
