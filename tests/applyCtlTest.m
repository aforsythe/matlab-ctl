classdef applyCtlTest < matlab.unittest.TestCase
% APPLYCTLTEST  Unit tests for apply_ctl.
%
%   Coverage:
%     - Shape / dtype (Mx1, Mx3, MxNx3; double + single)
%     - CTL dispatch (identity, scale2x, chained -ctl args)
%     - Byte-exact parity against ctlrender invoked via a TIFF
%       round-trip (the reference implementation)
%     - Edge cases: empty inputs, NaN/Inf pass-through, mtime-driven
%       cache reload, signature mismatch, missing commands
%
%   Usage:
%       >> runtests('applyCtlTest')
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

    properties (Constant)
        % Location of the ctlrender binary used by the parity tests.
        % Override via environment variable CTLRENDER or the class
        % property at use site if the default path doesn't exist.
        DefaultCtlrender = ...
            '/Users/alex/Source/CTL/build-ship-cpu/ctlrender/ctlrender';
    end

    properties
        IdCtl       % path to identity.ctl
        ScaleCtl    % path to scale2x.ctl
        ReqCtl      % path to required_param.ctl
        DefCtl      % path to defaulted_param.ctl
        AlphaCtl    % path to alpha_passthrough.ctl
        Ctlrender   % path to ctlrender binary
    end

    properties (TestParameter)
        % Each variant carries its input array plus the expected
        % output shape; Mx1 inputs expand to Mx3 on output, so we
        % can't just check out-size equals in-size.
        emptyShape = struct(...
            'MxNx3', struct('in', zeros(0, 0, 3), 'outSize', [0 0 3]), ...
            'Mx3',   struct('in', zeros(0, 3),    'outSize', [0 3]), ...
            'Mx1',   struct('in', zeros(0, 1),    'outSize', [0 3]));
    end

    methods (TestClassSetup)
        function resolveFixtures(testCase)
            here = fileparts(mfilename('fullpath'));
            testCase.IdCtl    = fullfile(here, 'identity.ctl');
            testCase.ScaleCtl = fullfile(here, 'scale2x.ctl');
            testCase.ReqCtl   = fullfile(here, 'required_param.ctl');
            testCase.DefCtl   = fullfile(here, 'defaulted_param.ctl');
            testCase.AlphaCtl = fullfile(here, 'alpha_passthrough.ctl');
            env = getenv('CTLRENDER');
            if ~isempty(env)
                testCase.Ctlrender = env;
            else
                testCase.Ctlrender = testCase.DefaultCtlrender;
            end
        end
    end

    methods (Test)
        % CTL Dispatch Tests

        function identityMxNx3(testCase)
            % The CTL interpreter path should round-trip to FP32 ULP.
            in = rand(64, 64, 3);
            out = apply_ctl(in, sprintf('-ctl %s', testCase.IdCtl));
            testCase.verifyEqual(out, in, AbsTol=1e-6);
        end

        function identitySingleInput(testCase)
            % single input flows through the MEX without a cast on
            % the way in; the output is always double on return.
            in = single(rand(4, 4, 3));
            out = apply_ctl(in, sprintf('-ctl %s', testCase.IdCtl));
            testCase.verifySize(out, [4 4 3]);
            testCase.verifyEqual(out, double(in), AbsTol=1e-7);
        end

        function identityMx3(testCase)
            in = rand(100, 3);
            out = apply_ctl(in, sprintf('-ctl %s', testCase.IdCtl));
            testCase.verifyEqual(out, in, AbsTol=1e-6);
        end

        function identityMx1(testCase)
            % Mx1 -> Mx3: the three output channels all equal the
            % input because identity.ctl is gray-preserving. Any CTL
            % that isn't would show a non-equal output here.
            in = linspace(0, 1, 50).';
            out = apply_ctl(in, sprintf('-ctl %s', testCase.IdCtl));
            testCase.verifySize(out, [50 3]);
            testCase.verifyEqual(out, [in, in, in], AbsTol=1e-6);
        end

        function scale2xMxNx3(testCase)
            in = rand(32, 32, 3);
            out = apply_ctl(in, sprintf('-ctl %s', testCase.ScaleCtl));
            testCase.verifyEqual(out, 2 * in, AbsTol=1e-6);
        end

        function chainIdentityThenScale(testCase)
            % identity -> scale2x == scale2x alone (2x).
            in = rand(32, 32, 3);
            cmd = sprintf('-ctl %s -ctl %s', testCase.IdCtl, testCase.ScaleCtl);
            out = apply_ctl(in, cmd);
            testCase.verifyEqual(out, 2 * in, AbsTol=1e-6);
        end

        function chainScaleScaleProducesFourX(testCase)
            % Two-stage scale confirms stage output feeds stage 2
            % input rather than both stages seeing the raw array.
            in = rand(32, 32, 3);
            cmd = sprintf('-ctl %s -ctl %s', testCase.ScaleCtl, ...
                          testCase.ScaleCtl);
            out = apply_ctl(in, cmd);
            testCase.verifyEqual(out, 4 * in, AbsTol=1e-6);
        end

        function cachedInterpreterStaysCorrect(testCase)
            % Back-to-back calls on the same .ctl hit the cached
            % interpreter; result must still be correct.
            in = rand(32, 32, 3);
            first  = apply_ctl(in, sprintf('-ctl %s', testCase.IdCtl));
            second = apply_ctl(in, sprintf('-ctl %s', testCase.IdCtl));
            testCase.verifyEqual(second, first);
            testCase.verifyEqual(second, in, AbsTol=1e-6);
        end

        % Parity Tests -- MEX output vs ctlrender reference

        function parityIdentityMxNx3(testCase)
            testCase.assumeCtlrender();
            rng(42);
            in = rand(32, 48, 3);
            mexOut = apply_ctl(in, sprintf('-ctl %s', testCase.IdCtl));
            refOut = ctlrender_via_disk(in, {testCase.IdCtl}, ...
                                     testCase.Ctlrender);
            testCase.verifyEqual(mexOut, refOut);  % AbsTol=0
        end

        function parityScale2xMxNx3(testCase)
            testCase.assumeCtlrender();
            in = rand(24, 36, 3);
            mexOut = apply_ctl(in, sprintf('-ctl %s', testCase.ScaleCtl));
            refOut = ctlrender_via_disk(in, {testCase.ScaleCtl}, ...
                                     testCase.Ctlrender);
            testCase.verifyEqual(mexOut, refOut);
        end

        function parityChainIdentityScale(testCase)
            testCase.assumeCtlrender();
            in = rand(40, 40, 3);
            cmd = sprintf('-ctl %s -ctl %s', testCase.IdCtl, ...
                          testCase.ScaleCtl);
            mexOut = apply_ctl(in, cmd);
            refOut = ctlrender_via_disk(in, ...
                {testCase.IdCtl, testCase.ScaleCtl}, ...
                testCase.Ctlrender);
            testCase.verifyEqual(mexOut, refOut);
        end

        function parityChainScaleScale(testCase)
            % Output escapes [0,1] range after 4x, catching any
            % surprise clamping in either backend.
            testCase.assumeCtlrender();
            in = 0.3 * rand(32, 32, 3);
            cmd = sprintf('-ctl %s -ctl %s', testCase.ScaleCtl, ...
                          testCase.ScaleCtl);
            mexOut = apply_ctl(in, cmd);
            refOut = ctlrender_via_disk(in, ...
                {testCase.ScaleCtl, testCase.ScaleCtl}, ...
                testCase.Ctlrender);
            testCase.verifyEqual(mexOut, refOut);
        end

        function parityNonSquare(testCase)
            % Non-square image exercises row vs column indexing.
            testCase.assumeCtlrender();
            in = rand(17, 91, 3);
            mexOut = apply_ctl(in, sprintf('-ctl %s', testCase.ScaleCtl));
            refOut = ctlrender_via_disk(in, {testCase.ScaleCtl}, ...
                                     testCase.Ctlrender);
            testCase.verifyEqual(mexOut, refOut);
        end

        % Edge Case Tests

        function emptyInputRoundTrip(testCase, emptyShape)
            out = apply_ctl(emptyShape.in, ...
                            sprintf('-ctl %s', testCase.IdCtl));
            testCase.verifySize(out, emptyShape.outSize);
            testCase.verifyEmpty(out);
        end

        function nonFinitePassthrough(testCase)
            % NaN, +Inf, -Inf, -0 survive FP32 cast byte-identically.
            rng(7);
            in = rand(8, 8, 3);
            in(1,1,1) = NaN;
            in(2,2,2) = Inf;
            in(3,3,3) = -Inf;
            in(4,4,1) = 0;
            in(4,4,2) = -0;
            out = apply_ctl(in, sprintf('-ctl %s', testCase.IdCtl));
            testCase.verifyTrue(isnan(out(1,1,1)));
            testCase.verifyTrue(isinf(out(2,2,2)) && out(2,2,2) > 0);
            testCase.verifyTrue(isinf(out(3,3,3)) && out(3,3,3) < 0);
            testCase.verifyEqual(out(4,4,1), 0);
            testCase.verifyEqual(out(4,4,2), 0);
            % Everywhere except the NaN cell the identity should be
            % bit-exact at FP32 precision.
            mask = ~isnan(in);
            testCase.verifyEqual(out(mask), in(mask), AbsTol=1e-7);
        end

        function mtimeTriggeredReload(testCase)
            % Edit a .ctl in place and confirm the next call picks up
            % the new source (cache keyed on path+mtime, not path).
            tmpdir = tempname;
            mkdir(tmpdir);
            c = onCleanup(@() rmdir(tmpdir, 's'));
            dynCtl = fullfile(tmpdir, 'dynamic.ctl');

            applyCtlTest.writeScaleCtl(dynCtl, 3.0);
            in = rand(16, 16, 3);
            outFirst = apply_ctl(in, sprintf('-ctl %s', dynCtl));
            testCase.verifyEqual(outFirst, 3 * in, AbsTol=1e-5);

            % APFS stores nanosecond mtime; a fresh write on its own
            % should change (sec,nsec). Pausing 1.1s defends against
            % filesystems with only second-resolution mtime.
            pause(1.1);
            applyCtlTest.writeScaleCtl(dynCtl, 5.0);
            outSecond = apply_ctl(in, sprintf('-ctl %s', dynCtl));
            testCase.verifyEqual(outSecond, 5 * in, AbsTol=1e-5);
        end

        function oddNameValuePairsRaises(testCase)
            % An odd-count trailing varargin can't be reshaped into
            % Name=Value pairs and must surface a clear error.
            testCase.verifyError( ...
                @() apply_ctl(rand(4, 3), testCase.IdCtl, 'lone'), ...
                'matlabctl:arg');
        end

        function nonStringParameterNameRaises(testCase)
            % First element of a Name=Value pair must be text. A
            % numeric in that slot should fail validation.
            testCase.verifyError( ...
                @() apply_ctl(rand(4, 3), testCase.IdCtl, 42, 1), ...
                'matlabctl:arg');
        end

        function flagStringWithoutPathRaises(testCase)
            % '-ctl' without a following token in the flag string
            % should raise a parse error.
            testCase.verifyError( ...
                @() apply_ctl(rand(4, 3), '-ctl'), ...
                'matlabctl:arg');
        end

        function flagStringSkipsUnknownFlags(testCase)
            % parse_flag_string drops tokens that aren't `-ctl` or
            % its path argument (e.g. ctlrender's `-format` and its
            % value). The call should still find the .ctl path and
            % round-trip identity correctly.
            in  = rand(4, 3);
            out = apply_ctl(in, sprintf('-format tiff8 -ctl %s', ...
                                        testCase.IdCtl));
            testCase.verifyEqual(out, in, AbsTol=1e-6);
        end

        function missingCommandsRaises(testCase)
            % commands is a required argument; calling with zero
            % args or an empty string must raise a clear error
            % rather than silently becoming a no-op.
            testCase.verifyError(@() apply_ctl(rand(4, 3)), ...
                                 'MATLAB:minrhs');
            testCase.verifyError(@() apply_ctl(rand(4, 3), ''), ...
                                 'matlabctl:arg');
        end

        % Call-Shape Tests -- commands can be a path, a list of paths,
        % or a ctlrender-style flag string.

        function singlePathChar(testCase)
            % Bare char path (no leading -ctl) is equivalent to
            % '-ctl <path>'.
            in = rand(8, 8, 3);
            out = apply_ctl(in, testCase.IdCtl);
            testCase.verifyEqual(out, in, AbsTol=1e-6);
        end

        function singlePathString(testCase)
            % String scalar accepted the same as a char vector.
            in = rand(8, 8, 3);
            out = apply_ctl(in, string(testCase.IdCtl));
            testCase.verifyEqual(out, in, AbsTol=1e-6);
        end

        function pathStringArrayChains(testCase)
            % Multi-element string array: each element is a path,
            % chained in order. Two scale2x stages == 4x.
            in = rand(8, 8, 3);
            chain = [string(testCase.ScaleCtl), ...
                     string(testCase.ScaleCtl)];
            out = apply_ctl(in, chain);
            testCase.verifyEqual(out, 4 * in, AbsTol=1e-6);
        end

        function pathCellstrChains(testCase)
            % Cell of char arrays: same semantics as the string
            % array form.
            in = rand(8, 8, 3);
            out = apply_ctl(in, {testCase.IdCtl, testCase.ScaleCtl});
            testCase.verifyEqual(out, 2 * in, AbsTol=1e-6);
        end

        function autoAlphaDefaultsToOne(testCase)
            % A CTL whose main() takes a varying float `aIn` without
            % a default (the ACES IDT/ODT shape) should still work:
            % apply_ctl auto-broadcasts aIn = 1.0 under this convention,
            % so the alpha_passthrough fixture premultiplies by 1.0 and
            % leaves RGB unchanged.
            in = rand(8, 8, 3);
            out = apply_ctl(in, testCase.AlphaCtl);
            testCase.verifyEqual(out, in, AbsTol=1e-6);
        end

        function alphaVaryingOverride(testCase)
            % aIn=0.5 should broadcast 0.5 as the varying alpha, so
            % the fixture returns 0.5 * in.
            in = rand(8, 8, 3);
            out = apply_ctl(in, testCase.AlphaCtl, aIn=0.5);
            testCase.verifyEqual(out, 0.5 * in, AbsTol=1e-6);
        end

        function uniformParamOverride(testCase)
            % required_param.ctl has `input float exposure` with no
            % default; exposure=2.5 satisfies it and the result is
            % 2.5 * in.
            in = rand(4, 4, 3);
            out = apply_ctl(in, testCase.ReqCtl, exposure=2.5);
            testCase.verifyEqual(out, 2.5 * in, AbsTol=1e-6);
        end

        function unknownParamRaises(testCase)
            % Typo protection: a Name=Value that no stage declares
            % must raise rather than silently do nothing. Error
            % message must name the offending parameter.
            try
                apply_ctl(rand(4, 3), testCase.IdCtl, exposur=2.5);
                testCase.verifyFail('expected an error');
            catch err
                testCase.verifyEqual(err.identifier, 'matlabctl:arg');
                testCase.verifySubstring(err.message, 'exposur');
            end
        end

        function unknownParamSuggestsNearMatch(testCase)
            % Near-match (edit distance within cutoff) triggers a
            % "Did you mean 'aIn'?" suggestion pointing at the real
            % declared name from alpha_passthrough.ctl.
            try
                apply_ctl(rand(4, 3), testCase.AlphaCtl, aI=0.5);
                testCase.verifyFail('expected an error');
            catch err
                testCase.verifyEqual(err.identifier, 'matlabctl:arg');
                testCase.verifySubstring(err.message, 'Did you mean');
                testCase.verifySubstring(err.message, 'aIn');
            end
        end

        function parallelDispatchDeterministic(testCase)
            % Once total samples exceed one chunk (32K), applyCtlStage
            % spawns multiple worker threads. Two back-to-back calls
            % on the same input must still produce bit-identical
            % output -- chunk assignment is deterministic by index,
            % so there's no race on the result.
            big = rand(400, 400, 3);    % ~160K samples = ~5 chunks
            out1 = apply_ctl(big, testCase.ScaleCtl);
            out2 = apply_ctl(big, testCase.ScaleCtl);
            testCase.verifyEqual(out2, out1);  % AbsTol=0
            testCase.verifyEqual(out1, 2 * big, AbsTol=1e-6);
        end

        function cacheInfoListsLoadedCtls(testCase)
            % After a successful apply_ctl, apply_ctl_cache_info
            % returns a struct array whose Path list contains the
            % CTL we just loaded and whose MtimeSec is a plausible
            % POSIX timestamp (positive, not in the future).
            apply_ctl(rand(3, 3, 3), testCase.IdCtl);
            info = apply_ctl_cache_info();
            paths = {info.Path};
            testCase.verifyTrue(any(strcmp(paths, char(testCase.IdCtl))));
            idx = find(strcmp(paths, char(testCase.IdCtl)), 1);
            testCase.verifyGreaterThan(info(idx).MtimeSec, 0);
            testCase.verifyLessThanOrEqual(info(idx).MtimeSec, ...
                posixtime(datetime('now', TimeZone='local')));
        end

        function cacheInfoPrintsWhenNoOutput(testCase)
            % Called without an output argument, the helper prints a
            % human-readable table. Capture stdout via evalc and
            % verify the path of the just-loaded CTL appears.
            apply_ctl(rand(3, 3, 3), testCase.IdCtl);
            txt = evalc('apply_ctl_cache_info');
            testCase.verifySubstring(txt, char(testCase.IdCtl));
            testCase.verifySubstring(txt, 'cached mtime');
        end


        function signaturePrintsRoleAnnotations(testCase)
            % Called without an output argument, get_ctl_signature
            % prints a table with per-input role annotations.
            % Capture and check the salient bits.
            txt = evalc("get_ctl_signature(testCase.AlphaCtl)");
            testCase.verifySubstring(txt, 'signature of');
            testCase.verifySubstring(txt, 'inputs:');
            testCase.verifySubstring(txt, 'outputs:');
            testCase.verifySubstring(txt, 'bound to R/G/B');
            % aIn has no CTL-source default in alpha_passthrough --
            % the auto-alpha annotation should fire.
            testCase.verifySubstring(txt, 'auto-defaults to 1.0');
        end

        function signaturePrintsRequiredAnnotation(testCase)
            % required_param.ctl declares a uniform 'exposure'
            % without a CTL-source default; it isn't named aIn, so
            % the print path classifies it as required.
            txt = evalc("get_ctl_signature(testCase.ReqCtl)");
            testCase.verifySubstring(txt, 'required');
            testCase.verifySubstring(txt, 'exposure');
        end

        function signaturePrintsDefaultedAnnotation(testCase)
            % defaulted_param.ctl declares 'exposure = 1.0' as a
            % varying parameter with a CTL-source default. The print
            % path's classifier hits the HasDefault branch and emits
            % the "defaulted in CTL; override optional" annotation.
            txt = evalc("get_ctl_signature(testCase.DefCtl)");
            testCase.verifySubstring(txt, 'exposure');
            testCase.verifySubstring(txt, 'defaulted in CTL');
        end

        function signatureReflectsDeclaredArgs(testCase)
            % get_ctl_signature returns a struct with Inputs and
            % Outputs arrays reflecting the CTL's main().
            sig = get_ctl_signature(testCase.AlphaCtl);
            testCase.verifyEqual(sig.Path, char(testCase.AlphaCtl));
            testCase.verifyEqual(numel(sig.Inputs),  4); % rIn, gIn, bIn, aIn
            testCase.verifyEqual(numel(sig.Outputs), 4); % rOut, gOut, bOut, aOut
            names = {sig.Inputs.Name};
            testCase.verifyEqual(names, {'rIn', 'gIn', 'bIn', 'aIn'});
            % aIn has no CTL default in this fixture.
            testCase.verifyFalse(sig.Inputs(4).HasDefault);
            % Identity fixture has no extras.
            sigId = get_ctl_signature(testCase.IdCtl);
            testCase.verifyEqual(numel(sigId.Inputs), 3);
        end

        function typoOnRequiredParamNamesCorrectly(testCase)
            % When a required param has no default AND the caller
            % passed a near-match, the "no default value" error
            % should point out the likely typo by name.
            try
                apply_ctl(rand(4, 3), testCase.ReqCtl, expsure=2.5);
                testCase.verifyFail('expected an error');
            catch err
                testCase.verifySubstring(err.message, 'did you mean');
                testCase.verifySubstring(err.message, 'exposure');
                testCase.verifySubstring(err.message, 'expsure');
            end
        end

        function dataArgOverrideRaises(testCase)
            % Name=Value can't set the first three CTL inputs -- they
            % come from IN. The error has to say that specifically,
            % not just "unknown name", because the name IS declared
            % by the CTL.
            try
                apply_ctl(rand(4, 3), testCase.IdCtl, rIn=0.5);
                testCase.verifyFail('expected an error');
            catch err
                testCase.verifyEqual(err.identifier, 'matlabctl:arg');
                testCase.verifySubstring(err.message, 'rIn');
                testCase.verifySubstring(err.message, 'input array');
            end
        end

        function programmaticNamedargs2cell(testCase)
            % A caller building params in a struct can splat them via
            % namedargs2cell; shouldn't matter to the MEX whether the
            % call site used `name=value` or `'name', value`.
            in = rand(4, 4, 3);
            s  = struct('exposure', 2.5);
            nv = namedargs2cell(s);
            out = apply_ctl(in, testCase.ReqCtl, nv{:});
            testCase.verifyEqual(out, 2.5 * in, AbsTol=1e-6);
        end

        function requiredParamRaises(testCase)
            % A CTL whose main() takes a non-defaulted uniform input
            % must be rejected up front with the parameter named.
            thrown = false;
            try
                apply_ctl(rand(8, 8, 3), ...
                          sprintf('-ctl %s', testCase.ReqCtl));
            catch err
                thrown = true;
                % The MEX re-raises via feval("error", id, msg).
                % Check both fields so the test tolerates either
                % MATLAB wrapping style.
                blob = sprintf('%s :: %s', err.identifier, err.message);
                testCase.verifySubstring(blob, 'exposure');
            end
            testCase.verifyTrue(thrown, ...
                'required_param CTL did not raise');
        end
    end

    methods (Access = private)
        function assumeCtlrender(testCase)
            % Skip parity tests cleanly if the ctlrender binary isn't
            % built at the expected path. Keeps runtests() from hard-
            % failing on a fresh checkout where only the MEX is built.
            testCase.assumeTrue(isfile(testCase.Ctlrender), ...
                sprintf('ctlrender not found at %s', testCase.Ctlrender));
        end
    end

    methods (Access = private, Static)
        function writeScaleCtl(path, factor)
            % Emit a tiny rIn/gIn/bIn -> rOut/gOut/bOut CTL that
            % multiplies each channel by FACTOR. CTL's grammar needs
            % each param on its own type declaration.
            arguments
                path    (1,:) char
                factor  (1,1) double
            end
            fid = fopen(path, 'w');
            c = onCleanup(@() fclose(fid));
            fprintf(fid, 'void main(\n');
            fprintf(fid, '    input  varying float rIn,\n');
            fprintf(fid, '    input  varying float gIn,\n');
            fprintf(fid, '    input  varying float bIn,\n');
            fprintf(fid, '    output varying float rOut,\n');
            fprintf(fid, '    output varying float gOut,\n');
            fprintf(fid, '    output varying float bOut)\n');
            fprintf(fid, '{\n');
            fprintf(fid, '    rOut = %.1f * rIn;\n', factor);
            fprintf(fid, '    gOut = %.1f * gIn;\n', factor);
            fprintf(fid, '    bOut = %.1f * bIn;\n', factor);
            fprintf(fid, '}\n');
        end
    end
end
