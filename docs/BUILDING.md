# Building ctl-matlab

macOS only. Intel and Apple Silicon -- CMake defaults to a fat-binary
build so one compiled `.mex*` loads on both.

## Prerequisites

Install the toolchain, C++ deps, and CTL via Homebrew:

```bash
brew install cmake imath openexr ctl
```

The `ctl` formula installs CTL 1.5.5 (Apache 2.0). If you'd rather
build CTL yourself or are iterating against a checkout, see
"Configure + build" below for the alternatives.

Xcode Command Line Tools supply Apple Clang:

```bash
xcode-select --install
```

MATLAB R2023b or later. CI verifies R2023b (floor) and R2025b
(newest verified) on push; PRs run R2025b only. The MEX itself
links against the R2018a C++ API, but the .m wrappers use
`arguments` blocks, `mustBeText`, Name=Value caller syntax, and
`buildtool` -- so R2023b is the lowest release the package as a
whole runs on.

**MATLAB version in `Matlab_ROOT_DIR`.** CMake's `find_package(Matlab)`
auto-detects `/Applications/MATLAB_R<YYYY><letter>.app` and picks
the newest it sees. If you have multiple MATLAB releases installed,
or MATLAB is at a non-standard path, set `Matlab_ROOT_DIR`
explicitly -- and note the release is **baked into the path**, not
a glob:

```bash
# Correct: specific release
export Matlab_ROOT_DIR=/Applications/MATLAB_R2025b.app

# WRONG: CMake won't expand this
export Matlab_ROOT_DIR=/Applications/MATLAB_R*.app
```

Next year's MATLAB upgrade means updating this variable, re-running
`cmake`, and rebuilding.

Homebrew paths differ by arch: `/opt/homebrew/` on Apple Silicon,
`/usr/local/` on Intel. `find_package(Imath CONFIG)` and
`find_package(OpenEXR CONFIG)` pick up either automatically.

`apply_ctl_mex` uses only the public `Ctl::Interpreter` /
`Ctl::FunctionCall` / `Ctl::FunctionArg` API, so any libIlmCtl
build exposing those symbols will link.

## Configure + build

`./build.sh` with no arguments handles the common case: it auto-
discovers CTL by trying `brew --prefix ctl` first, then a sibling
`../CTL` checkout with a build dir under `build/`, `build-release/`,
or `build-ship-cpu/` containing `libIlmCtl.a`.

```bash
./build.sh
```

Three other modes are available when the auto-discovery doesn't fit:

```bash
./build.sh --fetch                      # clone aces-aswf/CTL@ctl-1.5.5 into ./build
./build.sh /path/to/CTL                 # explicit source dir; build dir auto-picked
./build.sh /path/to/CTL /path/to/build  # fully explicit
```

`--fetch` adds a one-time CTL compile (~30-60s on M-series hardware)
to the first configure. The clone lands under `build/_deps/ctl-src`
and isn't shared with subsequent ctl-matlab checkouts; pin that with
`-DCTL_FETCH_TAG=<other-tag>` if needed.

Equivalent CMake longhand:

```bash
cd /path/to/ctl-matlab

# brew ctl
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCTL_FROM_BREW=ON

# fetch
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCTL_FETCH=ON

# explicit dev build
cmake -B build -DCMAKE_BUILD_TYPE=Release \
    -DCTL_SOURCE_DIR=/path/to/CTL \
    -DCTL_BUILD_DIR=/path/to/CTL/build

cmake --build build -j
```

Output lands in `src/apply_ctl_mex.mexmaca64` (or
`.mexmaci64` on Intel). The `.m` wrapper `src/apply_ctl.m` sits
next to it; `addpath` the `src/` dir in MATLAB and both are
picked up.

## Try it from MATLAB

Open the project and apply one of the fixture CTLs:

```matlab
>> openProject('/Users/alex/Source/ctl-matlab/ctl-matlab.prj')
>> idCtl = fullfile(currentProject().RootFolder, 'tests', 'identity.ctl');
>> apply_ctl(0.18, idCtl)
ans =
    0.1800    0.1800    0.1800
```

Opening the project puts `src/` and `tests/` on the path. A bare
scalar like `0.18` is replicated to R=G=B on entry and the full
3-channel output is returned. See `examples/GettingStarted.m` for
a richer walkthrough.

## Switching CTL builds

Useful when comparing CTL variants (e.g. an optimized interpreter
branch against master). Re-run `cmake` with different
`-DCTL_SOURCE_DIR` / `-DCTL_BUILD_DIR` and rebuild. The binding
only uses the public Interpreter / FunctionCall API, so any
libIlmCtl build that exposes those symbols will link. Runtime
performance varies across builds (optimized variants can be several
times faster on large images), but correctness is invariant.

```bash
cmake -B build-alt \
    -DCTL_SOURCE_DIR=/path/to/CTL \
    -DCTL_BUILD_DIR=/path/to/CTL/build-alt
cmake --build build-alt -j
```

## Universal binary (single `.mex*` for Intel + Apple Silicon)

This is the default -- `CMAKE_OSX_ARCHITECTURES=x86_64;arm64` is set
in the top-level CMake. **Note:** your CTL static libs must
themselves be fat for the link to succeed. If CTL was built on
Apple Silicon only, you'll see link errors about missing x86_64
symbols. In that case, either:

1. Rebuild CTL as a universal binary (`-DCMAKE_OSX_ARCHITECTURES=x86_64;arm64`),
   or
2. Override this repo's arch to arm64-only:
   `cmake -B build -DCMAKE_OSX_ARCHITECTURES=arm64 ...`.

For dev on an Apple Silicon machine, arm64-only is the pragmatic
path until there's a reason to ship Intel.
