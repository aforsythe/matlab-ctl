function benchApplyCtl(options)
% BENCHAPPLYCTL  Time MEX vs ctlrender subprocess across image sizes.
%
%   benchApplyCtl runs a sweep of identity-CTL round-trips through
%   both the in-process MEX path and a shell-out to ctlrender, and
%   prints a table of cold / warm per-call wall-clock times plus the
%   warm-speedup ratio.
%
%     - Cold:  first call of the session (MEX pays one-time CTL
%              module parse + cache; subprocess path pays module
%              load every call).
%     - Warm:  min of subsequent calls (MEX hits cache; subprocess
%              path still pays spawn + module load + TIFF I/O every
%              time).
%
%   INPUTS: (none)
%
%   OPTIONAL INPUTS (Name-Value arguments):
%       Sizes      - Image side lengths to sweep (1xK int vector)
%                    Default: [64, 256, 512, 1024, 2048]
%       Reps       - Repetitions per size; 1 cold + (Reps-1) warm,
%                    warm = min (integer) Default: 6
%       Ctls       - One or more CTL paths to exercise as a chain.
%                    Accepts a scalar string/char or a string array
%                    (string, char, or cellstr). Default: the
%                    project's tests/identity.ctl (single stage).
%       Ctlrender  - Path to the ctlrender binary (char).
%                    Default: /Users/alex/Source/CTL/build-ship-cpu/ctlrender/ctlrender
%
%   REQUIRES:
%       A built ctlrender binary at `Ctlrender` (errors early if
%       missing).
%
%   NOTES:
%       No `clear mex` between sweeps -- that path triggered a
%       destructor ordering crash on R2025b when CTL's static state
%       was torn down mid-session. One cold + N-1 warm per size
%       gives enough signal.
%
%   EXAMPLE:
%       >> benchApplyCtl
%       >> benchApplyCtl(Sizes=[256 1024], Reps=10)
%       >> benchApplyCtl(Ctls='/path/to/my_transform.ctl')
%       >> % IDT -> ODT chain, e.g. ACEScg -> Rec.709 OT
%       >> benchApplyCtl(Ctls=[idt, odt])
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

arguments
    options.Sizes      (1,:) double ...
        {mustBeInteger, mustBePositive} = [64, 256, 512, 1024, 2048]
    options.Reps       (1,1) double ...
        {mustBeInteger, mustBeGreaterThan(options.Reps, 1)} = 6
    options.Ctls       {mustBeText} = string.empty
    options.Ctlrender  (1,:) char ...
        = '/Users/alex/Source/CTL/build-ship-cpu/ctlrender/ctlrender'
end
    % Normalize `Ctls` to a string array of paths. Default: single
    % identity.ctl from this project.
    chain = string(options.Ctls);
    if isempty(chain)
        this  = fileparts(mfilename('fullpath'));
        chain = string(fullfile(this, 'identity.ctl'));
    end

    if ~isfile(options.Ctlrender)
        error('matlabctl:test', ...
              'ctlrender not found at %s', options.Ctlrender);
    end
    for i = 1:numel(chain)
        if ~isfile(chain(i))
            error('matlabctl:test', ...
                  'CTL file not found at %s', chain(i));
        end
    end

    reps = options.Reps;

    fprintf('\n===== bench: apply_ctl (MEX) vs ctlrender subprocess =====\n');
    if isscalar(chain)
        fprintf('CTL: %s\n', chain(1));
    else
        fprintf('CTL chain (%d stages):\n', numel(chain));
        for i = 1:numel(chain), fprintf('  [%d] %s\n', i, chain(i)); end
    end
    fprintf('Repetitions per size: %d (1 cold + %d warm, warm = min)\n\n', ...
            reps, reps-1);

    fprintf('%-10s %-24s %-26s %-10s\n', 'size', ...
            'MEX cold / warm [ms]', 'ctlrender cold / warm [ms]', ...
            'warm speedup');
    fprintf('%-10s %-24s %-26s %-10s\n', '----', ...
            '--------------------', '--------------------------', ...
            '------------');

    for dim = options.Sizes
        img = rand(dim, dim, 3);

        mexTimes = time_n(reps, @() apply_ctl(img, chain));
        refTimes = time_n(reps, @() ctlrender_via_disk(img, ...
            cellstr(chain), options.Ctlrender));

        mexCold = mexTimes(1) * 1000;
        mexWarm = min(mexTimes(2:end)) * 1000;
        refCold = refTimes(1) * 1000;
        refWarm = min(refTimes(2:end)) * 1000;

        fprintf('%-10s %-24s %-26s %6.1fx\n', ...
                sprintf('%dx%d', dim, dim), ...
                sprintf('%.2f / %.2f', mexCold, mexWarm), ...
                sprintf('%.2f / %.2f', refCold, refWarm), ...
                refWarm / mexWarm);
    end

    fprintf('\nNotes:\n');
    fprintf('  - MEX cold = first call of the session for this .ctl\n');
    fprintf('    (module parse + SimdInterpreter init; trivial CTLs\n');
    fprintf('    take <1 ms, ACES v2-class modules ~150-400 ms).\n');
    fprintf('  - Subsequent MEX calls hit the cache and skip that work.\n');
    fprintf('  - The ctlrender subprocess path has no equivalent cache:\n');
    fprintf('    every call pays spawn + module load + TIFF I/O.\n');
    fprintf('  - Speedup grows with smaller sizes because the per-call\n');
    fprintf('    fixed overhead dominates at small image sizes.\n\n');
end

function times = time_n(N, fn)
    arguments
        N   (1,1) double {mustBeInteger, mustBePositive}
        fn  (1,1) function_handle
    end
    times = zeros(1, N);
    for i = 1:N
        t0 = tic;
        fn();
        times(i) = toc(t0);
    end
end
