#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
#
# Configure + build the apply_ctl MEX. Discovers CTL automatically
# (Homebrew first, then a `../CTL` sibling clone) and falls back to
# FetchContent when invoked with --fetch.
#
# Usage:
#   ./build.sh                              # auto-discover (brew, then ../CTL)
#   ./build.sh /path/to/CTL                 # explicit source, auto-pick build dir
#   ./build.sh /path/to/CTL /path/to/build  # fully explicit
#   ./build.sh --fetch                      # clone + build aces-aswf/CTL@ctl-1.5.5

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"

usage() {
    cat <<EOF >&2
Usage: ./build.sh [CTL_SOURCE_DIR [CTL_BUILD_DIR]]
       ./build.sh --fetch

With no arguments, auto-discovers CTL in this order:
  1. Homebrew (brew --prefix ctl)
  2. Sibling ../CTL with a build dir under build/, build-release/,
     or build-ship-cpu/ containing libIlmCtl.a

Options:
  --fetch          Clone aces-aswf/CTL@ctl-1.5.5 into the build tree
                   and build it as a subproject. Use when neither
                   brew-ctl nor a CTL checkout is available.

Optional environment:
  Matlab_ROOT_DIR  Specific MATLAB install (e.g.
                   /Applications/MATLAB_R2025b.app). CMake
                   autodetects when unset on standard paths.
EOF
    exit 1
}

# Pick the first build dir under <src> that contains libIlmCtl.a.
# Echo the path on success, print nothing on miss.
find_build_dir() {
    local src="$1"
    local cand
    for cand in build build-release build-ship-cpu; do
        if [[ -f "$src/$cand/lib/IlmCtl/libIlmCtl.a" ]]; then
            echo "$src/$cand"
            return 0
        fi
    done
    return 1
}

CMAKE_ARGS=(
    -S "$ROOT"
    -B "$BUILD_DIR"
    -DCMAKE_BUILD_TYPE=Release
)

case "${1:-}" in
    --fetch)
        echo "[build.sh] mode: --fetch (clone aces-aswf/CTL@ctl-1.5.5)"
        CMAKE_ARGS+=(-DCTL_FETCH=ON)
        ;;
    -h|--help)
        usage
        ;;
    "")
        # No args -- discover. Brew first, then sibling ../CTL.
        if BREW_CTL="$(brew --prefix ctl 2>/dev/null)" \
                && [[ -d "$BREW_CTL" ]]; then
            echo "[build.sh] mode: Homebrew CTL at $BREW_CTL"
            CMAKE_ARGS+=(-DCTL_FROM_BREW=ON)
        else
            SIBLING="$ROOT/../CTL"
            if [[ -d "$SIBLING" ]] \
                    && SIBLING_BUILD="$(find_build_dir "$SIBLING")"; then
                echo "[build.sh] mode: sibling CTL at $SIBLING"
                echo "[build.sh] using build dir: $SIBLING_BUILD"
                CMAKE_ARGS+=(
                    -DCTL_SOURCE_DIR="$(cd "$SIBLING" && pwd)"
                    -DCTL_BUILD_DIR="$(cd "$SIBLING_BUILD" && pwd)")
            else
                cat <<EOF >&2
[build.sh] No CTL found.

Tried:
  1. Homebrew ctl       (\`brew --prefix ctl\` -- not installed)
  2. Sibling ../CTL     (no build dir with libIlmCtl.a found)

Pick one:
  brew install ctl && ./build.sh
  ./build.sh /path/to/your/CTL [/path/to/build]
  ./build.sh --fetch    # clone aces-aswf/CTL@ctl-1.5.5 into ./build
EOF
                exit 1
            fi
        fi
        ;;
    *)
        # Explicit path(s).
        CTL_SRC="$1"
        if [[ ! -d "$CTL_SRC" ]]; then
            echo "[build.sh] CTL source dir not found: $CTL_SRC" >&2
            exit 1
        fi
        if [[ $# -ge 2 ]]; then
            CTL_BLD="$2"
        else
            if ! CTL_BLD="$(find_build_dir "$CTL_SRC")"; then
                cat <<EOF >&2
[build.sh] No CTL build dir found under $CTL_SRC.

Looked for: build/, build-release/, build-ship-cpu/ containing
libIlmCtl.a. Build CTL first, e.g.:

    cd $CTL_SRC
    cmake -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j

Then re-run ./build.sh, or pass an explicit build dir:
    ./build.sh $CTL_SRC /path/to/build
EOF
                exit 1
            fi
            echo "[build.sh] auto-picked build dir: $CTL_BLD"
        fi
        CMAKE_ARGS+=(
            -DCTL_SOURCE_DIR="$(cd "$CTL_SRC" && pwd)"
            -DCTL_BUILD_DIR="$(cd "$CTL_BLD" && pwd)")
        ;;
esac

if [[ -n "${Matlab_ROOT_DIR:-}" ]]; then
    CMAKE_ARGS+=(-DMatlab_ROOT_DIR="$Matlab_ROOT_DIR")
fi

echo "+ cmake ${CMAKE_ARGS[*]}"
cmake "${CMAKE_ARGS[@]}"

echo "+ cmake --build $BUILD_DIR -j"
cmake --build "$BUILD_DIR" -j

echo
echo "Built MEX: $ROOT/src/apply_ctl_mex.mexmac*"
