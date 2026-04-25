%[text] # Getting Started with matlab-ctl
%[text] This walkthrough applies CTL (Color Transformation Language) transforms to a handful of MATLAB array shapes, starting with a single scalar and building up to an image. Before running, make sure:
%[text] - the matlab-ctl project is open: `openProject('matlab-ctl.prj')` at the repo root
%[text] - the MEX has been built via CMake (see `docs/BUILDING.md`) -- opening the project does **not** build the MEX, it only adds `src/` and `tests/` to the path \
%%
%[text] ## Locate fixtures
%[text] The project puts `src/` and `tests/` on the path automatically; here we just grab absolute paths to two fixture CTLs we will reuse below. Storing them as `string` lets us pass them straight into `apply_ctl` without a `sprintf('-ctl %s', ...)` dance.
projRoot = string(currentProject().RootFolder);
idCtl    = fullfile(projRoot, 'tests', 'identity.ctl');
scaleCtl = fullfile(projRoot, 'tests', 'scale2x.ctl');
%%
%[text] ## A single scalar
%[text] A plain number is interpreted as a neutral input: the MEX replicates it to R=G=B, runs the transform, and returns all three output channels as a 1x3 row. CTL transforms aren't required to preserve neutrality -- a matrix whose rows don't sum equally, a chromatic adaptation, or a gamut-mapping stage can all turn R=G=B input into a non-neutral output, and hiding the other two channels would mask that. Through `identity.ctl` all three channels come back equal to the input.
out = apply_ctl(0.5, idCtl)
%[text] Through `scale2x.ctl` every channel doubles; `scale2x` is gray-preserving, so R=G=B on output too.
out = apply_ctl(0.5, scaleCtl)
%%
%[text] ## A single RGB triplet as a 1x3 row vector
%[text] A 1-by-3 row vector is one RGB sample. The three columns become R, G, and B respectively, and the output is also 1-by-3.
rgb = [0.2, 0.5, 0.8];
out = apply_ctl(rgb, scaleCtl)
%%
%[text] ## Gotcha: a 3x1 column is NOT an RGB triplet
%[text] A 3-by-1 column means three independent neutral samples, not one RGB triplet. Each scalar is replicated to R=G=B and runs through the transform independently. Compare:
rowRgb  = [0.2, 0.5, 0.8];
colRamp = [0.2; 0.5; 0.8];
rowOut = apply_ctl(rowRgb,  scaleCtl)
colOut = apply_ctl(colRamp, scaleCtl)
%[text] The row is one 3-channel sample and comes back 1x3 (`[0.4 1.0 1.6]`). The column is three separate 1-channel samples, each replicated to R=G=B, so it comes back 3x3 -- one row per sample, three columns for R, G, B. For gray-preserving transforms like scale2x the three output columns are equal, but that isn't guaranteed for a general transform. If you mean "one RGB triplet", always use the row form.
%%
%[text] ## A list of RGB triplets (Mx3)
%[text] Stack triplets as rows to process a list of colors in a single call. Output shape matches the input.
colors = [0.1 0.1 0.1;
          0.5 0.5 0.5;
          0.8 0.2 0.2;
          0.2 0.8 0.2];
out = apply_ctl(colors, scaleCtl)
%%
%[text] ## RGBA
%[text] apply\_ctl only takes three-channel input. If you have RGBA, strip the alpha before the call, apply CTL to the RGB portion, and concatenate the original alpha back on. Most transforms (including every ACES OT) only touch the RGB channels and leave alpha untouched, so carrying alpha around manually on the MATLAB side is harmless.
rgba         = [0.2, 0.5, 0.8, 1.0];
rgb          = rgba(:, 1:3);
alpha        = rgba(:, 4);
rgbProcessed = apply_ctl(rgb, scaleCtl);
out = [rgbProcessed, alpha]
%%
%[text] ## Image arrays (MxNx3)
%[text] The full image form. MATLAB stores arrays column-major, and the MEX grabs the raw buffer pointer and converts per-channel planes with parallel workers, so there is no per-pixel loop overhead on the MATLAB side.
img = rand(4, 6, 3);
out = apply_ctl(img, scaleCtl);
size(out)
max(abs(out(:) - 2*img(:)))
%%
%[text] ## Chaining transforms
%[text] To run several transforms in sequence, pass a string array of paths -- each stage's output feeds the next stage's input. Here `scale2x` composed with itself produces 4x.
out = apply_ctl(img, [scaleCtl scaleCtl]);
max(abs(out(:) - 4*img(:)))
%%
%[text] ## ctlrender-style flag string
%[text] `apply_ctl` also accepts a ctlrender flag string with one or more `-ctl <path>` tokens. This form is recognized by a leading `-` and parses the same way `ctlrender`'s CLI does, so call sites that already build a flag string (e.g. a port from a shell script, or a config that stores the command as a single string) work without reshaping.
cmd = sprintf('-ctl %s -ctl %s', scaleCtl, scaleCtl);
out = apply_ctl(img, cmd);
max(abs(out(:) - 4*img(:)))
%[text] Tokens other than `-ctl` in the flag string are silently dropped. For new code the string-array form above is more idiomatic MATLAB, but the flag-string form is always there for compatibility with pipelines that already speak ctlrender.
%%
%[text] ## Overriding CTL parameters
%[text] A CTL `main()` can declare inputs beyond the R/G/B triplet -- think per-call exposure, alpha, peak luminance, EOTF selector. Any such extra input that doesn't have a CTL-source default must be supplied by the caller as a trailing `Name=Value` pair after the commands argument. `required_param.ctl` in this project's tests directory declares `input float exposure` with no default; it multiplies each channel by that uniform:
reqCtl = fullfile(projRoot, 'tests', 'required_param.ctl');
neutrals = [0.1; 0.5; 0.9];
out = apply_ctl(neutrals, reqCtl, exposure=2.5)
%[text] The name on the left-hand side of `=` can be anything the CTL declares as a `main()` input, including varying inputs. `alpha_passthrough.ctl` declares `varying float aIn` with no default and premultiplies RGB by it. Alpha is a special case: without an override, `apply_ctl` auto-broadcasts `aIn = 1.0` (the ACES convention that alpha passes through as opaque), so the chain "just works" on ACES IDTs and OTs that declare alpha without defaulting it:
alphaCtl = fullfile(projRoot, 'tests', 'alpha_passthrough.ctl');
out = apply_ctl(neutrals, alphaCtl)
%[text] Passing an explicit `aIn` replaces the 1.0 default:
out = apply_ctl(neutrals, alphaCtl, aIn=0.5)
%%
%[text] ## Discovering what a CTL accepts
%[text] Not sure what names a given `.ctl` declares? `get_ctl_signature` prints the main()'s input and output parameters with per-input role annotations, so you can tell at a glance which names are overridable, which are bound to the R/G/B channels of the input array, and which are required.
get_ctl_signature(reqCtl)
%[text] When called with an output argument, the helper returns the same data as a struct so you can filter it programmatically -- for example, list every overridable extra whose CTL-source default is missing:
sig = get_ctl_signature(alphaCtl);
extras = sig.Inputs(4:end);
required = extras(~[extras.HasDefault]);
fprintf('extras requiring a Name=Value: %s\n', strjoin({required.Name}, ', '));
%%
%[text] ## What can you override, and what happens if you typo
%[text] Override values are scalar numerics -- `double`, `single`, `int32`, or `logical`. Vector / matrix / CTL-struct parameters (like the `Chromaticities` struct that ACES v2 OTs use for limiting primaries) aren't supported as overrides today. Uniform params get their value written once; varying params get the value broadcast to every sample in every chunk.
%[text] Names must match an input the CTL actually declares. A typo raises a clear error naming the offending parameter (demonstrated here against `identity.ctl`, which has no extra inputs so the typo can't accidentally satisfy anything):
try
    apply_ctl(neutrals, idCtl, xposure=2.5);   % nothing named xposure
catch err
    fprintf('typo caught:\n  id: %s\n  msg: %s\n', err.identifier, err.message);
end
%[text] The first three CTL inputs -- typically `rIn`, `gIn`, `bIn`, but technically whatever the CTL author named them -- are bound to the R/G/B planes of the input array. You can't override them via `Name=Value`; if you want different R/G/B values, change the input array. The error tells you specifically that:
try
    apply_ctl(neutrals, idCtl, rIn=0.5);       % rIn is bound to IN
catch err
    fprintf('collision caught:\n  id: %s\n  msg: %s\n', err.identifier, err.message);
end
%[text] For chains, the override applies to every stage that declares a matching input. Stages that don't declare the name simply don't see the override; the typo check passes as long as at least one stage consumes each name.
%%
%[text] ## Interpreter caching
%[text] The first call against a new `.ctl` pays the parse + codegen cost -- a few milliseconds for a trivial CTL, a few hundred for an ACES v2 Output Transform. Subsequent calls against the same `.ctl` hit a cached interpreter. If you edit the `.ctl` on disk, the next call picks up the change automatically (the cache is keyed on path + mtime). We write a fresh `.ctl` to a temp directory here so the cold measurement really is cold.
freshDir = tempname;
mkdir(freshDir);
cleanup = onCleanup(@() rmdir(freshDir, 's'));
freshCtl = fullfile(freshDir, 'fresh.ctl');
fid = fopen(freshCtl, 'w');
fprintf(fid, ['void main(\n' ...
              '    input  varying float rIn,\n' ...
              '    input  varying float gIn,\n' ...
              '    input  varying float bIn,\n' ...
              '    output varying float rOut,\n' ...
              '    output varying float gOut,\n' ...
              '    output varying float bOut)\n' ...
              '{ rOut = rIn; gOut = gIn; bOut = bIn; }\n']);
fclose(fid);
t1 = tic; apply_ctl(img, freshCtl); coldMs = toc(t1)*1000;
t2 = tic; apply_ctl(img, freshCtl); warmMs = toc(t2)*1000;
fprintf('cold: %.2f ms\nwarm: %.2f ms\n', coldMs, warmMs)
%%
%[text] ## Inspecting the cache
%[text] `apply_ctl_cache_info` lists every interpreter currently loaded in the MEX, with the mtime each was cached against. When a call is behaving oddly, this is usually the first diagnostic -- if the on-disk mtime doesn't match the cached value, the next call will reload; if it does match and you still suspect staleness, `clear mex` drops the cache.
apply_ctl_cache_info()
%[text] Called with an output argument, the helper returns the list as a struct array for programmatic inspection.
info = apply_ctl_cache_info();
fprintf('currently cached: %d interpreter(s)\n', numel(info));
%%
%[text] ## Interruption
%[text] Long CTL compute (e.g. an ACES v2 Output Transform at 4K resolution) polls MATLAB's interrupt flag between chunks, so Ctrl+C aborts cleanly partway through instead of being queued until the MEX returns. You won't see that here -- everything in this walkthrough completes in milliseconds -- but it's there if you need it.
%%
%[text] ## Further reading
%[text] - `docs/BUILDING.md` -- CMake + CTL build prerequisites, including the MATLAB version baked into `Matlab_ROOT_DIR`
%[text] - `README.md` -- multi-file CTL (ACES v2 Output Transforms) via the `CTL_MODULE_PATH` environment variable
%[text] - `get_ctl_signature(path)` -- list a CTL's declared main() inputs and outputs
%[text] - `apply_ctl_cache_info` -- inspect loaded interpreters and their cached mtimes
%[text] - `runtests('applyCtlTest')` -- the full test suite
%[text] - `benchApplyCtl(Ctls=<path or [path1 path2]>)` -- MEX vs `ctlrender` subprocess wall-clock sweep \
%[text] Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences. SPDX-License-Identifier: Apache-2.0.

%[appendix]{"version":"1.0"}
%---
%[metadata:view]
%   data: {"layout":"inline"}
%---
