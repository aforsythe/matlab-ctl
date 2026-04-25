function out = apply_ctl(in, commands, varargin)
% APPLY_CTL  Apply one or more CTL transforms to a MATLAB array via MEX.
%
%   out = apply_ctl(in, commands) applies one or more CTL transforms
%   to IN and returns the 3-channel result.  COMMANDS accepts any of:
%
%     - a single .ctl path                       (char or string)
%     - a list of .ctl paths, chained in order   (string array or cellstr)
%     - a ctlrender flag string with `-ctl` tokens (char or string)
%
%   Additional trailing Name=Value pairs override CTL parameters by
%   name across every stage in the chain.
%
%   INPUTS:
%       in       - Input values (float array; Mx1, Mx3, or MxNx3)
%       commands - CTL transform specifier in one of the forms above
%
%   OPTIONAL INPUTS (Name-Value arguments):
%       <paramName> - Override the CTL input named <paramName>. Value
%                     must be a scalar numeric (double, single, int32,
%                     or logical). For uniform CTL params the value
%                     is written once; for varying CTL params the
%                     value is broadcast to every sample. Every name
%                     must be declared as an input by at least one
%                     stage in the chain -- otherwise the call
%                     raises, catching typos.
%
%   OUTPUTS:
%       out - Transform result (double array). Always 3-channel
%             because CTL transforms are not required to preserve
%             neutrality:
%                 Mx1   -> Mx3   (scalar/column replicated to R=G=B
%                                 on entry; all three output channels
%                                 returned)
%                 Mx3   -> Mx3   (row-per-RGB-triplet form)
%                 MxNx3 -> MxNx3 (image array)
%
%   NOTES:
%       Interpreters are cached across calls keyed on (.ctl path +
%       mtime). The CTL module-parse cost (sub-millisecond for
%       trivial CTLs, ~150-400 ms for ACES v2 modules) is paid once
%       per session per unique .ctl file. Call `clear mex` to drop
%       the cache.
%
%       Multi-file CTLs (e.g. ACES v2 Output Transforms) need a
%       module search path. Set CTL_MODULE_PATH in MATLAB before
%       calling; see README for details.
%
%       A CTL stage may declare extra inputs beyond rIn/gIn/bIn.
%       These are resolved in order of: Name=Value override by name,
%       then the ACES alpha convention (any varying float named
%       `aIn` auto-defaults to 1.0), then the CTL-source default,
%       then an error.
%
%       The flag-string form is disambiguated from the single-path
%       form by a leading `-`. Paths that themselves start with `-`
%       are not supported -- use the string-array / cellstr form
%       instead.
%
%       To build a params struct programmatically and pass it as
%       Name=Value pairs, use MATLAB's `namedargs2cell`:
%           s  = struct('exposure', 2.5, 'aIn', 0.5);
%           nv = namedargs2cell(s);
%           out = apply_ctl(in, ctl, nv{:});
%
%   EXAMPLE:
%       neutrals = [0; 0.18; 0.5; 1.0];
%
%       % Single path
%       out = apply_ctl(neutrals, '/path/to/identity.ctl');
%
%       % Chain (IDT -> ODT) as a string array
%       idt = "/path/to/CSC.Academy.ACEScg_to_ACES.ctl";
%       odt = "/path/to/Output.Academy.Rec709.ctl";
%       out = apply_ctl(neutrals, [idt, odt]);
%
%       % Override a varying input (here: broadcast alpha = 0.5
%       % to every sample the ODT sees)
%       out = apply_ctl(neutrals, odt, aIn=0.5);
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

arguments
    in        {mustBeFloat, mustBeReal}
    commands  {mustBeText}
end
arguments (Repeating)
    varargin
end
    paths = resolve_commands(commands);
    if isempty(paths)
        error('matlabctl:arg', ...
              'commands must name at least one .ctl file');
    end
    params = params_struct_from_namevalue(varargin);
    out = apply_ctl_mex(in, paths, params);
end

function s = params_struct_from_namevalue(nv)
%PARAMS_STRUCT_FROM_NAMEVALUE Reshape a flat {name, value, ...} cell
% into a scalar struct whose fieldnames are the names.  Matches
% MATLAB's built-in Name=Value call-site translation, so callers
% using either `name=value` or `'name', value` syntax arrive here
% the same way.
    s = struct();
    if mod(numel(nv), 2) ~= 0
        error('matlabctl:arg', ...
              ['parameter overrides must come in Name=Value pairs; ', ...
               'got %d trailing argument(s)'], numel(nv));
    end
    for k = 1:2:numel(nv)
        name = nv{k};
        if ~(ischar(name) || (isstring(name) && isscalar(name))) ...
                || isempty(char(name))
            error('matlabctl:arg', ...
                  'parameter name at position %d is not a non-empty string', k);
        end
        s.(char(name)) = nv{k+1};
    end
end

function paths = resolve_commands(commands)
%RESOLVE_COMMANDS Normalize the COMMANDS argument to a cellstr of
% .ctl paths.  Accepts a scalar path, a list of paths (string array
% or cellstr), or a ctlrender-style flag string with `-ctl` tokens.

    % Path list: string array with more than one element, or any
    % cell array.
    if (isstring(commands) && ~isscalar(commands)) || iscell(commands)
        paths = cellstr(commands);
        return
    end
    % Scalar string or char vector: flag string or a lone path.
    s = strtrim(char(commands));
    if isempty(s)
        paths = {};
    elseif startsWith(s, '-')
        paths = parse_flag_string(s);
    else
        paths = {s};
    end
end

function paths = parse_flag_string(s)
%PARSE_FLAG_STRING Extract .ctl paths from a ctlrender-style string
% like '-ctl a.ctl -ctl b.ctl'.  Tokens other than `-ctl` flags and
% their path arguments (e.g. `-param`, `-format`) are silently
% dropped; scalar-parameter passthrough is deferred.
    paths = {};
    toks = strsplit(s);
    i = 1;
    while i <= numel(toks)
        if strcmp(toks{i}, '-ctl')
            if i + 1 > numel(toks)
                error('matlabctl:arg', '-ctl requires a following path');
            end
            paths{end+1} = toks{i+1}; %#ok<AGROW>
            i = i + 2;
        else
            i = i + 1;
        end
    end
end
