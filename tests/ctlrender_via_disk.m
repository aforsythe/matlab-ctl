function out = ctlrender_via_disk(in, ctl_paths, ctlrender_path, opts)
% CTLRENDER_VIA_DISK  Apply CTL by shelling out to ctlrender over a TIFF.
%
%   out = ctlrender_via_disk(in, ctl_paths, ctlrender_path) writes IN
%   to a 32-bit float TIFF, spawns ctlrender to apply the CTL chain
%   given in CTL_PATHS, and reads the output TIFF back as double.
%
%   Used as the reference implementation for the parity tests:
%   ctlrender ships with CTL upstream and its SimdInterpreter is
%   what apply_ctl_mex also links against, so matching outputs
%   confirm the MEX's marshal path is correct. Also used by
%   benchApplyCtl to measure the wall-clock cost of the subprocess
%   + TIFF I/O approach.
%
%   INPUTS:
%       in             - Image array (MxNx3 numeric)
%       ctl_paths      - CTL files to apply in order (cell of char)
%       ctlrender_path - Path to the ctlrender binary (char)
%
%   OPTIONAL INPUTS (Name-Value):
%       WithAlpha - When true, write a 4-channel RGBA float TIFF
%                   with alpha = 1.0 instead of RGB. Required for
%                   ACES IDT/ODT chains where the CTL declares a
%                   varying `aIn` without a default -- ctlrender
%                   binds aIn from the input's alpha channel.
%                   Default: false.
%       ExtraEnv  - 1xN string array of "VAR=value" assignments to
%                   prepend to the ctlrender command (e.g. for
%                   CTL_MODULE_PATH on multi-file transforms).
%                   Default: empty.
%
%   OUTPUTS:
%       out - Transform result (MxNx3 double). ctlrender writes RGBA
%             TIFFs even on RGB input; the alpha channel is stripped
%             on read-back.
%
%   EXAMPLE:
%       ctlr = '/path/to/ctlrender';
%       img  = rand(64, 64, 3);
%       out  = ctlrender_via_disk(img, {'/path/to/identity.ctl'}, ctlr);
%
%       % ACES ODT chain with alpha and module path
%       out = ctlrender_via_disk(img, {idt, odt}, ctlr, ...
%                                WithAlpha=true, ...
%                                ExtraEnv="CTL_MODULE_PATH=/aces/lib");
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

arguments
    in              (:,:,3) {mustBeNumeric, mustBeReal}
    ctl_paths       cell
    ctlrender_path  (1,:) char {mustBeFile}
    opts.WithAlpha  (1,1) logical = false
    opts.ExtraEnv   string = strings(1, 0)
end

    tempdir_local = tempname;
    mkdir(tempdir_local);
    c = onCleanup(@() rmdir(tempdir_local, 's'));

    in_tif  = fullfile(tempdir_local, 'in.tif');
    out_tif = fullfile(tempdir_local, 'out.tif');

    % Write MxNx3 double as a 32-bit float RGB (or RGBA) TIFF.
    % MATLAB's imwrite doesn't handle float TIFF directly, so use
    % the Tiff class.
    if opts.WithAlpha
        payload = cat(3, single(in), ones(size(in,1), size(in,2), 'single'));
        nSamples = 4;
    else
        payload = single(in);
        nSamples = 3;
    end
    t = Tiff(in_tif, 'w');
    tagstruct.ImageLength         = size(in, 1);
    tagstruct.ImageWidth          = size(in, 2);
    tagstruct.Photometric         = Tiff.Photometric.RGB;
    tagstruct.BitsPerSample       = 32;
    tagstruct.SampleFormat        = Tiff.SampleFormat.IEEEFP;
    tagstruct.SamplesPerPixel     = nSamples;
    tagstruct.PlanarConfiguration = Tiff.PlanarConfiguration.Chunky;
    tagstruct.Compression         = Tiff.Compression.None;
    if nSamples == 4
        % Mark the 4th channel as alpha-associated so ctlrender's
        % TIFF reader binds it to aIn. AssociatedAlpha matches the
        % "premultiplied alpha = 1.0" semantics here (no-op for
        % alpha = 1).
        tagstruct.ExtraSamples = Tiff.ExtraSamples.AssociatedAlpha;
    end
    setTag(t, tagstruct);
    write(t, payload);
    close(t);

    % Build ctlrender invocation: each CTL file preceded by a -ctl
    % flag, matching the MEX's own parsed command shape.
    ctl_flags = '';
    for i = 1:numel(ctl_paths)
        ctl_flags = [ctl_flags, ' -ctl ', ctl_paths{i}]; %#ok<AGROW>
    end
    env_prefix = '';
    if ~isempty(opts.ExtraEnv)
        env_prefix = [char(strjoin(opts.ExtraEnv, ' ')), ' '];
    end
    cmd = sprintf('%s"%s"%s -format tiff32 -force "%s" "%s"', ...
                  env_prefix, ctlrender_path, ctl_flags, ...
                  in_tif, out_tif);

    [status, result] = system(cmd);
    if status ~= 0
        error('matlabctl:ctlrender', ...
              'ctlrender failed (status %d):\n%s', status, result);
    end

    % Read output TIFF back.  ctlrender writes RGBA (4 channels) even
    % when input was RGB, so strip the alpha on return.
    raw = double(imread(out_tif));
    if size(raw, 3) > 3
        out = raw(:,:,1:3);
    else
        out = raw;
    end
end
