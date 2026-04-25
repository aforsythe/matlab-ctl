function out = ctlrender_via_disk(in, ctl_paths, ctlrender_path)
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
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

arguments
    in              (:,:,3) {mustBeNumeric, mustBeReal}
    ctl_paths       cell
    ctlrender_path  (1,:) char {mustBeFile}
end

    tempdir_local = tempname;
    mkdir(tempdir_local);
    c = onCleanup(@() rmdir(tempdir_local, 's'));

    in_tif  = fullfile(tempdir_local, 'in.tif');
    out_tif = fullfile(tempdir_local, 'out.tif');

    % Write MxNx3 double as a 32-bit float RGB TIFF.  MATLAB's
    % imwrite doesn't handle float TIFF directly, so use the Tiff
    % class.
    t = Tiff(in_tif, 'w');
    tagstruct.ImageLength         = size(in, 1);
    tagstruct.ImageWidth          = size(in, 2);
    tagstruct.Photometric         = Tiff.Photometric.RGB;
    tagstruct.BitsPerSample       = 32;
    tagstruct.SampleFormat        = Tiff.SampleFormat.IEEEFP;
    tagstruct.SamplesPerPixel     = 3;
    tagstruct.PlanarConfiguration = Tiff.PlanarConfiguration.Chunky;
    tagstruct.Compression         = Tiff.Compression.None;
    setTag(t, tagstruct);
    write(t, single(in));
    close(t);

    % Build ctlrender invocation: each CTL file preceded by a -ctl
    % flag, matching the MEX's own parsed command shape.
    ctl_flags = '';
    for i = 1:numel(ctl_paths)
        ctl_flags = [ctl_flags, ' -ctl ', ctl_paths{i}]; %#ok<AGROW>
    end
    cmd = sprintf('"%s"%s -format tiff32 -force "%s" "%s"', ...
                  ctlrender_path, ctl_flags, in_tif, out_tif);

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
