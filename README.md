# ctl-matlab

[![CI](https://github.com/aforsythe/ctl-matlab/actions/workflows/ci.yml/badge.svg)](https://github.com/aforsythe/ctl-matlab/actions/workflows/ci.yml)
[![MATLAB](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/aforsythe/ctl-matlab/main/reports/badge/tested_with.json)](#testing)
[![Coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/aforsythe/ctl-matlab/main/reports/badge/coverage.json)](#testing)
[![Code issues](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/aforsythe/ctl-matlab/main/reports/badge/code_issues.json)](#testing)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Native MATLAB bindings for [CTL](https://github.com/aces-aswf/CTL) (the
Color Transformation Language). A MEX function applies CTL
transforms to MATLAB arrays in-process via `libIlmCtl` /
`libIlmCtlSimd`, with persistent interpreter caching across calls.

## Why

An alternative to applying CTL from MATLAB is shelling out to the
`ctlrender` binary with a TIFF round-trip. That works, but most of
the wall-clock there goes to subprocess spawn, TIFF encode/decode,
and per-call CTL module parsing rather than color math. Calling
`libIlmCtl` in-process from a MEX skips all of those.

Measured end-to-end on M4 Max (16 cores: 12 performance +
4 efficiency) running the full ACES v2 Rec.709 100-nit BT.1886
Output Transform (a real-world
compute-heavy CTL: four imported `Lib.Academy.*` modules, per-pixel
transcendentals, CAM16 gamut mapping):

| Image   | ctlrender subprocess | MEX (in-process) | Speedup |
| ------- | -------------------: | ---------------: | ------: |
| 64x64   |             229 ms   |         7.6 ms   |    30x  |
| 256x256 |             250 ms   |          13 ms   |    19x  |
| 512x512 |             285 ms   |          35 ms   |   8.2x  |
| 1024^2  |             396 ms   |         130 ms   |   3.0x  |
| 2048^2  |             880 ms   |         495 ms   |   1.8x  |

Warm (min of 5 iterations; first call excluded so the MEX-side
module parse doesn't dominate small-image rows). Reproduce with
`tests/benchApplyCtl.m`.

Plus: no temporary files, no `cd` gymnastics, no argv string
concatenation, and interpreters are cached so repeated calls
amortize the module-parse cost -- sub-millisecond for trivial CTLs,
up to a few hundred milliseconds for large modules like the ACES v2
OutputTransform.

## How it works

1. MATLAB array enters the MEX via `apply_ctl(in, [idt, odt])`
   (string array of CTL paths, chained in order).
2. MEX grabs the raw column-major buffer pointer, splits into per-
   channel float planes using parallel `std::thread` workers.
3. The requested CTL file is looked up in a process-scoped
   `Ctl::SimdInterpreter` cache keyed on `(realpath, mtime)`. First
   hit parses + codegens the module; subsequent hits reuse the
   loaded interpreter. The cache evicts on mtime change so edits to
   the .ctl are picked up without `clear mex`.
4. `FunctionCall` executes against the channel planes in tiles of
   up to `SimdInterpreter::maxSamples()` (32K default). Multiple
   `FunctionCall`s pulled from the same interpreter are dispatched
   across `hardware_concurrency()` worker threads, mirroring
   `ctlrender`'s tile-parallel pattern, so compute scales across
   cores rather than chunks.
5. Output planes are written back via parallel workers into a fresh
   MATLAB double array of the input's shape.

Long calls poll MATLAB's interrupt flag between chunks, so Ctrl+C
during a multi-second ACES OT at 4K aborts cleanly (surfacing as
`apply_ctl interrupted (Ctrl+C pressed during dispatch)`) instead
of being queued until return.

Interpreter link target is swappable across CTL builds -- the MEX
only uses the public `Interpreter` / `FunctionCall` API, so it
links cleanly against any build of libIlmCtl that exposes those
symbols.

## Requirements

- macOS (Intel or Apple Silicon). Linux and Windows are out of
  scope.
- MATLAB R2023b or newer. The .m wrappers use `arguments` blocks,
  Name=Value caller syntax, and `mustBeText`; CI drives the build
  via `buildtool`. The compiled MEX binary itself only needs the
  R2018a C++ API, but the wrapper functions won't run on releases
  below R2023b.
- CMake 3.22+ and a C++17 compiler (Apple Clang is fine).
- CTL itself, picked up automatically via `brew install ctl`,
  a sibling `../CTL` checkout, or `./build.sh --fetch`. Developers
  iterating on CTL can still point at their own checkout
  explicitly; see `docs/BUILDING.md`.
- Homebrew `imath` and `openexr` (CTL transitive deps).

## Quick Start

```bash
brew install cmake imath openexr ctl
git clone <this repo> ctl-matlab
cd ctl-matlab
./build.sh
```

`./build.sh` with no arguments auto-discovers CTL: it tries
`brew --prefix ctl` first, then a sibling `../CTL` checkout. If
neither is available, run `./build.sh --fetch` to have CMake clone
`aces-aswf/CTL@ctl-1.5.5` into the build tree. Developers iterating
against their own CTL clone can still pass paths explicitly:

```bash
./build.sh /path/to/CTL                 # auto-pick build dir
./build.sh /path/to/CTL /path/to/build  # fully explicit
```

See `docs/BUILDING.md` for the raw CMake invocation, prerequisites,
and notes on shipping the compiled MEX.

The compiled `.mexmaca64` (or `.mexmaci64` on Intel) lands in
`src/` next to `apply_ctl.m`. From MATLAB, double-click
`ctl-matlab.prj` (or call `openProject('ctl-matlab.prj')`) to open
the project -- this auto-adds `src/` and `tests/` to the path:

```matlab
>> openProject('/path/to/ctl-matlab/ctl-matlab.prj')
>> in  = rand(256, 256, 3);
>> out = apply_ctl(in, "/path/to/my/transform.ctl");
```

If you don't want to use a project, `addpath('/path/to/ctl-matlab/src')`
is enough to reach `apply_ctl`.

For a guided tour of the API, open
[`examples/GettingStarted.m`](examples/GettingStarted.m) and run it
cell-by-cell in the Editor (with the project open).

## Usage

`apply_ctl(in, commands)`. The canonical form is a string array
(or cellstr) of CTL paths, chained in order:

```matlab
out = apply_ctl(in, [idt, odt]);
out = apply_ctl(in, ["foo.ctl", "bar.ctl"]);
out = apply_ctl(in, {'foo.ctl', 'bar.ctl'});
```

A single path can be passed bare (char or string), which is just
the one-element case of the above:

```matlab
out = apply_ctl(in, "foo.ctl");
out = apply_ctl(in, 'foo.ctl');
```

A `ctlrender`-style flag string is also accepted for CLI parity:

```matlab
out = apply_ctl(in, '-ctl foo.ctl -ctl bar.ctl');
```

Disambiguation is a leading `-`: forms starting with `-` are
parsed as flag strings, otherwise `commands` is treated as one or
more paths.

Supported shapes. Output is always 3-channel because a CTL
transform isn't required to preserve neutrality (a non-row-sum-
normalized matrix, a chromatic adaptation, or a gamut-mapping
stage can all produce a non-neutral output from neutral input):

| Input   | Output  | Notes                                                |
| ------- | ------- | ---------------------------------------------------- |
| `Mx1`   | `Mx3`   | Each scalar replicated to R=G=B on entry; all three output channels returned (slice the G column yourself if the transform is known gray-preserving) |
| `Mx3`   | `Mx3`   | RGB triples as three columns                         |
| `MxNx3` | `MxNx3` | Image array                                          |

Inputs may be `double` or `single`; outputs are always `double`.
Internal compute runs in FP32.

Non-finite values (`NaN`, `+Inf`, `-Inf`) pass through identity
transforms byte-identically.

### Multi-file transforms (ACES v2)

Transforms with `import` statements (e.g. ACES v2 Output
Transforms) need a module search path so the interpreter can
resolve imports. Set `CTL_MODULE_PATH` in MATLAB before calling;
the MEX forwards it to `Ctl::Interpreter::setModulePaths` on every
fresh load, so changing the env var between sessions Just Works.

Realistic pipeline: an input transform (ACEScg to ACES 2065-1)
followed by an output transform (Rec.709 100-nit BT.1886):

```matlab
>> setenv('CTL_MODULE_PATH', '/path/to/aces/aces-core/lib')
>> aces = '/path/to/aces';
>> idt  = string(fullfile(aces, 'aces-input-and-colorspaces', ...
...          'ACEScg', 'CSC.Academy.ACEScg_to_ACES.ctl'));
>> odt  = string(fullfile(aces, 'aces-output', 'd65', 'rec709', ...
...          'Output.Academy.Rec709-D65_100nit_in_Rec709-D65_BT1886.ctl'));
>> neutrals = [0; 0.01; 0.18; 0.5; 0.9; 1.0];
>> out = apply_ctl(neutrals, [idt, odt]);
```

Every ACES IDT and ODT declares a varying `aIn` (alpha) input.
Whether it carries a CTL-source default varies by transform --
older IDTs and CSCs typically don't; current ODTs typically do
(`aIn = 1.0`). Either case "just works" without an explicit
override: when there's no source-level default, `apply_ctl` falls
back to the ACES convention (auto-broadcast `aIn = 1.0`, opaque
passthrough); when there is one, the CTL default fires. To
override the alpha broadcast, or to set any other input the CTL
exposes (uniform or varying), pass it as a trailing Name=Value
pair:

```matlab
>> out = apply_ctl(neutrals, [idt, odt], aIn=0.5);
```

Any `name=value` pair after the commands argument is treated as a
CTL parameter override applied by name across the chain. A name
that no stage in the chain declares raises a "did you mean..."
error (typo protection). To see what names a given CTL accepts,
use the signature helper:

```matlab
>> get_ctl_signature(odt)
signature of /path/to/Output.Academy.Rec709-D65_100nit_in_Rec709-D65_BT1886.ctl
  inputs:
    rIn                varying  float     (bound to R/G/B of input array)
    gIn                varying  float     (bound to R/G/B of input array)
    bIn                varying  float     (bound to R/G/B of input array)
    aIn                varying  float     (defaulted in CTL; override optional)
  outputs:
    rOut               varying  float
    gOut               varying  float
    bOut               varying  float
    aOut               varying  float
```

Call `sig = get_ctl_signature(path)` to get the same data as a
scalar struct for programmatic use (fields `Path`, `Inputs`,
`Outputs`; inputs carry `Name`, `Type`, `Varying`, `HasDefault`).

To build overrides programmatically and splat them at the call
site, use MATLAB's `namedargs2cell`:

```matlab
>> s  = struct('aIn', 0.5);
>> nv = namedargs2cell(s);
>> out = apply_ctl(neutrals, [idt, odt], nv{:});
```

First call pays the full parse + codegen for every `.ctl` in the
chain plus their imports (ACES v2 OT walks four `Lib.Academy.*.ctl`
files; budget ~500-800 ms cold on M4 Max for the OT alone).
Subsequent calls against the same chain hit the cache; warm
wall-clock for a handful of samples is a few milliseconds.

## Testing

Quickest form, once the project is open:

```matlab
>> openProject('ctl-matlab.prj')
>> runtests('applyCtlTest')
```

Or run the full build pipeline (static analysis + tests with
JUnit + Cobertura coverage reports in `reports/`). Requires
R2023b+ for `buildtool`:

```matlab
>> buildtool          % runs check + test
>> buildtool test     % tests only
>> buildtool clean    % delete reports/
```

Parity tests invoke `ctlrender` as a subprocess to confirm the MEX
output matches the reference implementation byte-for-byte. They
auto-skip if the binary isn't at the default path; override via:

```matlab
>> setenv('CTLRENDER', '/path/to/ctlrender')
>> runtests('applyCtlTest')
```

An end-to-end ACES v2 integration test (`acesV2ChainParity`) runs
the same parity check against a real ACEScg-to-Rec.709 IDT → ODT
chain. It activates when `CTL_MODULE_PATH` points at an ACES core
lib directory; the test self-locates by scanning the path for
`Lib.Academy.OutputTransform.ctl` and resolves the IDT and ODT
relative to the parent ACES tree, so the same env var an ACES
workflow already needs is the only configuration:

```matlab
>> setenv('CTL_MODULE_PATH', '/path/to/aces/aces-core/lib')
>> runtests('applyCtlTest/acesV2ChainParity')
```

When `CTL_MODULE_PATH` is unset or doesn't contain an ACES library,
this test skips cleanly and the rest of the suite still runs.

## Helpers & diagnostics

`src/` ships two helper functions alongside `apply_ctl` for
inspection:

| Function                  | Purpose                                                       |
| ------------------------- | ------------------------------------------------------------- |
| `get_ctl_signature(path)` | Print or return the declared `main()` signature of a `.ctl`. Shows each input's name, type, varying-vs-uniform, and whether it has a CTL-source default -- useful for discovering what Name=Value overrides a transform accepts. |
| `apply_ctl_cache_info()`  | List the interpreters currently cached in the MEX, with the mtime each was loaded against. Answers "did my `.ctl` edit pick up?" -- compare cached mtime to current on-disk. |

`tests/benchApplyCtl.m` is the end-to-end wall-clock benchmark.
Pass a single CTL path or a chain via `Ctls=`:

```matlab
>> benchApplyCtl(Ctls=odt, Sizes=[512 2048], Reps=6)
>> benchApplyCtl(Ctls=[idt, odt])   % IDT -> ODT chain
```

## Limitations

Gathered in one place so expectations are clear:

- **macOS only.** Intel and Apple Silicon are both targets; Linux
  and Windows are out of scope.
- **MATLAB R2023b+** for the .m wrappers (`arguments` blocks,
  `mustBeText`, Name=Value call syntax, `buildtool`). The MEX
  binary alone needs only R2018a's C++ API, but it's not useful
  without the wrappers. CI verifies R2023b and R2025b on push to
  main; PRs run R2025b only.
- **Shapes.** `Mx1`, `Mx3`, and `MxNx3` only. RGBA inputs must be
  split to apply CTL to the RGB portion, then the alpha
  re-concatenated (see `examples/GettingStarted.m`).
- **Output is always double, always 3-channel.** Single inputs are
  cast to double on return. Extra output args the CTL declares
  beyond `rOut/gOut/bOut` (e.g. `aOut`) are computed by the
  interpreter but not returned to MATLAB.
- **Name=Value overrides are scalar numerics only** --
  `double`/`single`/`int32`/`logical`. Vector, matrix, and CTL
  struct types (`Chromaticities`, `float3`, etc.) aren't
  overridable through the wrapper.
- **CTL-source `const` declarations aren't overridable at all.**
  ACES v2's `peakLuminance`, `eotf_enum`, `limitingPri`, and
  `encodingPri` are declared `const` at file scope in the `.ctl`
  source, not as `main()` parameters -- the values bake in at parse
  time. Changing them requires editing the `.ctl`.
- **First three CTL inputs are bound to the R/G/B channels of the
  input array.** They're not overridable via Name=Value -- the
  value comes from `IN` itself. If the CTL names these
  differently (rare), attempting `oldName=v` raises a clear error.
- **Overrides apply across every stage in a chain.** A given
  `Name=Value` hits every stage that declares a matching input;
  stages that don't declare it are silently skipped (names the
  chain declares nowhere at all trigger a typo error). There's no
  per-stage override syntax today; ctlrender's sequential
  `-param` semantics isn't replicated.
- **Interpreter cache mtime tracks the main `.ctl` only, not its
  imports.** Editing `Lib.Academy.SomeModule.ctl` that an ACES OT
  imports won't invalidate the OT's cache entry because the OT's
  own mtime is unchanged. Run `clear mex` when iterating on
  imported modules.
- **Paths starting with `-` aren't supported in the single-path
  scalar form.** The leading-`-` disambiguation would route them
  to the flag-string parser. Pass them through the
  string-array or cellstr form instead.
- **The built `.mexmaca64` isn't redistributable as-is.** It
  carries absolute Homebrew paths to its C++ dependencies, so
  recipients have to build from source per `docs/BUILDING.md`.

## Project Structure

```
ctl-matlab/
|-- CMakeLists.txt
|-- build.sh                     Auto-discovering CMake wrapper
|-- buildfile.m                  MATLAB buildtool: check + test + clean
|-- buildUtilities/              Shields.io-endpoint JSON generators
|-- ctl-matlab.prj               MATLAB project (opens src/ + tests/)
|-- README.md
|-- LICENSE
|-- CITATION.cff
|-- .github/                     GitHub Actions CI workflow
|-- resources/                   MATLAB project metadata
|-- docs/
|   `-- BUILDING.md              CMake + CTL build prerequisites
|-- mex/
|   `-- apply_ctl_mex.cpp        C++ MEX source (links libIlmCtl)
|-- src/
|   |-- apply_ctl.m              Public MATLAB wrapper
|   |-- get_ctl_signature.m      CTL main() introspection helper
|   |-- apply_ctl_cache_info.m   Interpreter-cache diagnostic helper
|   `-- apply_ctl_mex.*          Compiled MEX (built by cmake --build)
|-- tests/                       MATLAB test suite + CTL fixtures
`-- examples/
    `-- GettingStarted.m         Walkthrough script
```

## Citation

See [`CITATION.cff`](CITATION.cff).

## License

Apache License 2.0; see [`LICENSE`](LICENSE). Each source file
carries an `SPDX-License-Identifier: Apache-2.0` header.

Third-party components retain their own licenses: CTL (the library
this MEX links against) is Apache 2.0; Imath and OpenEXR are
BSD-3-Clause; MATLAB's MEX C++ API headers ship with MATLAB under
MathWorks' terms.

## Copyright

Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences.
