# SPDX-FileCopyrightText: 2026 CBC/Radio-Canada
# SPDX-License-Identifier: Apache-2.0
# Multi-stage Dockerfile for the MXL ABI tester.
# Build context: the repository root.
#
# Stage 1 - build the MXL SDK from dmf-mxl/mxl at the commit pinned in MXL_COMMIT
# Stage 2 - build the React + Vite frontend
# Stage 3 - build the C++ backend against the SDK from stage 1
# Stage 4 - runtime: libmxl, the binary, the built frontend. No node, no cmake.

# ------------------------------------------------------------------------------
# Stage 1 - MXL SDK. Same build as cbcrc-ea/eng-upp-media-mxl-sdk, minus the Rust
# GStreamer plugin: this tool needs only the headers, libmxl and mxl-info.
# ------------------------------------------------------------------------------
FROM ubuntu:24.04 AS mxl-builder

ARG DEBIAN_FRONTEND=noninteractive

# Pinned to match upstream's .devcontainer/Dockerfile.
ARG CLANG_VERSION=19

# vcpkg checkout, pinned for reproducibility. It must be recent enough to know every
# port version upstream's vcpkg.json asks for with `version>=`, so it is NOT upstream's
# builtin-baseline. Bump when upstream's vcpkg.json requires something newer.
ARG VCPKG_COMMIT=b81cab76a175645e047601da8f982ad86bff1cc3

# GStreamer is not linked into libmxl, but tools/mxl-gst is configured with the rest
# of the tree, so its dev packages must be present for cmake to succeed.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        build-essential pkg-config \
        cmake ninja-build \
        nasm autoconf automake libtool bison flex \
        zip unzip tar \
        clang-${CLANG_VERSION} lld-${CLANG_VERSION} llvm-${CLANG_VERSION} \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        libglib2.0-dev \
        libsysprof-capture-4-dev \
    && rm -rf /var/lib/apt/lists/*

# The CMake presets ask for the unsuffixed clang/clang++, and CMAKE_LINKER_TYPE=LLD
# makes clang look for ld.lld on PATH.
RUN ln -sf /usr/bin/clang-${CLANG_VERSION}   /usr/bin/clang \
 && ln -sf /usr/bin/clang++-${CLANG_VERSION} /usr/bin/clang++ \
 && ln -sf /usr/bin/ld.lld-${CLANG_VERSION}  /usr/bin/ld.lld

# CMakePresets.json hardcodes the toolchain file at ~/vcpkg. Not a shallow clone:
# manifest-mode versioning `git show`s historical objects, which --depth 1 lacks;
# --filter=blob:none keeps the full graph while fetching file contents lazily.
RUN git clone --filter=blob:none https://github.com/microsoft/vcpkg.git /root/vcpkg \
 && git -C /root/vcpkg checkout ${VCPKG_COMMIT} \
 && /root/vcpkg/bootstrap-vcpkg.sh --disableMetrics
ENV VCPKG_ROOT=/root/vcpkg

# Copied here, after the toolchain layers, so an SDK bump does not rebuild them.
COPY MXL_COMMIT /workspace/MXL_COMMIT
WORKDIR /workspace
RUN commit="$(tr -d '[:space:]' < MXL_COMMIT)" \
 && test ${#commit} -eq 40 || { echo "MXL_COMMIT must hold a 40-character sha" >&2; exit 1; } \
 && git init mxl \
 && cd mxl \
 && git remote add origin https://github.com/dmf-mxl/mxl.git \
 && git fetch --depth 1 origin "${commit}" \
 && git checkout FETCH_HEAD

RUN --mount=type=cache,target=/root/.cache/vcpkg,sharing=locked \
    cmake -S /workspace/mxl -B /workspace/mxl/build/Linux-Clang-Release \
      --preset Linux-Clang-Release \
      -DBUILD_DOCS=OFF \
      -DBUILD_TESTS=OFF \
 && cmake --build /workspace/mxl/build/Linux-Clang-Release --target mxl mxl-info

# Shipped under its SONAME (libmxl.so.<major>), not its build name
# (libmxl.so.<major>.<minor>), so an upstream minor bump needs no edit here.
RUN set -eux \
 && mkdir -p /out/lib /out/tools \
 && so="$(find /workspace/mxl/build/Linux-Clang-Release/lib -name 'libmxl.so.*.*' -type f)" \
 && test -n "${so}" || { echo "no libmxl.so.<major>.<minor> found in the build tree" >&2; exit 1; } \
 && soname="$(readelf -d "${so}" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')" \
 && test -n "${soname}" || { echo "libmxl has no SONAME" >&2; exit 1; } \
 && cp "${so}" "/out/lib/${soname}" \
 && ln -s "${soname}" /out/lib/libmxl.so \
 && cp /workspace/mxl/build/Linux-Clang-Release/tools/mxl-info/mxl-info /out/tools/

# ------------------------------------------------------------------------------
# Stage 2 - frontend
#
# node:22, not the spec's node:18: Vite 8.2.2 and @vitejs/plugin-react 6.1.0
# both declare engines ^20.19.0 || >=22.12.0
# ------------------------------------------------------------------------------
FROM node:22-bookworm-slim AS frontend-builder

WORKDIR /build

COPY frontend/package.json \
     frontend/package-lock.json \
     ./

RUN npm ci

COPY frontend/ ./

RUN npm run build

# -------------------------------------------------------------------------------
# Stage 3 - backend. Ubuntu 24.04 ships both dependencies, so nothing is vendored.
# -------------------------------------------------------------------------------
FROM ubuntu:24.04 AS backend-builder

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        g++ cmake make pkg-config nlohmann-json3-dev libcpp-httplib-dev \
    && rm -rf /var/lib/apt/lists/*

# Laid out as the CMakeLists expects: $MXL_ROOT/lib/include for the headers,
# $MXL_ROOT/build/$MXL_PRESET/lib for the .so.
COPY --from=mxl-builder /workspace/mxl/lib/include /opt/mxl/lib/include
COPY --from=mxl-builder /out/lib/ /opt/mxl/build/Linux-Clang-Release/lib/

COPY backend /build/backend
WORKDIR /build/backend
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release -DMXL_ROOT=/opt/mxl \
 && cmake --build build -j

# --------------------------------------------------------------------------------
# Stage 4 - runtime. No node, no cmake, no headers: nothing here compiles.
# The headers were a build-time contract (what the calls look like); what runs
# needs only the .so that implements them, found by SONAME at load time.
# --------------------------------------------------------------------------------
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcpp-httplib0.14t64 curl \
    && rm -rf /var/lib/apt/lists/*

# Registered in ld.so.conf.d rather than passed as LD_LIBRARY_PATH: the binary's
# baked RPATH points into stage 3 and does not exist here.
COPY --from=mxl-builder /out/lib/ /opt/mxl/lib/
RUN echo /opt/mxl/lib > /etc/ld.so.conf.d/mxl.conf \
 && ldconfig

# Cross-checking convenience only; the backend does not depend on it.
COPY --from=mxl-builder /out/tools/mxl-info /opt/mxl/tools/mxl-info/mxl-info

COPY --from=backend-builder  /build/backend/build/abi-tester /app/abi-tester
COPY --from=frontend-builder /build/dist                     /app/frontend/dist
COPY flows         /app/flows
COPY scenarios     /app/scenarios
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV MXL_DOMAIN_ROOT=/mxl-domain
ENV FRONTEND_DIST=/app/frontend/dist
ENV SCENARIO_DIR=/app/scenarios

EXPOSE 9600
ENTRYPOINT ["/entrypoint.sh"]
