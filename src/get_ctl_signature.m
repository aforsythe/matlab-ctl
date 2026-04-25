function varargout = get_ctl_signature(ctlPath)
% GET_CTL_SIGNATURE  Print or return the signature of a CTL main().
%
%   get_ctl_signature(ctlPath) loads CTLPATH and prints the
%   declared input and output parameters of its main() function --
%   the names, CTL types, varying-vs-uniform classification, and
%   whether each input has a CTL-source default. Useful for figuring
%   out what names a given transform accepts as Name=Value overrides
%   to apply_ctl.
%
%   sig = get_ctl_signature(ctlPath) suppresses the print and
%   returns the signature as a scalar struct.
%
%   INPUTS:
%       ctlPath - Path to a .ctl file (char or string)
%
%   OUTPUTS (optional):
%       sig - Struct with fields:
%               Path     (char) absolute .ctl path
%               Inputs   (1xN struct array, fields Name, Type,
%                         Varying, HasDefault)
%               Outputs  (1xM struct array, fields Name, Type,
%                         Varying)
%
%   EXAMPLE:
%       % Interactive inspection
%       get_ctl_signature('/path/to/Output.Academy.Rec709.ctl')
%
%       % Programmatic
%       sig = get_ctl_signature(ctlPath);
%       extras = sig.Inputs(4:end);          % skip rIn/gIn/bIn
%       required = extras(~[extras.HasDefault]);
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

arguments
    ctlPath {mustBeText, mustBeFile}
end
    sig = apply_ctl_mex('signature', char(ctlPath));
    if nargout == 0
        prettyPrintSignature(sig);
    else
        varargout{1} = sig;
    end
end

function prettyPrintSignature(sig)
%PRETTYPRINTSIGNATURE Render a signature struct as aligned text.
    fprintf('signature of %s\n', sig.Path);

    fprintf('  inputs:\n');
    for i = 1:numel(sig.Inputs)
        arg = sig.Inputs(i);
        role = classifyInputRole(i, arg);
        fprintf('    %-18s %-8s %-8s  %s\n', ...
                arg.Name, varyingTag(arg.Varying), arg.Type, role);
    end

    fprintf('  outputs:\n');
    for i = 1:numel(sig.Outputs)
        arg = sig.Outputs(i);
        fprintf('    %-18s %-8s %-8s\n', ...
                arg.Name, varyingTag(arg.Varying), arg.Type);
    end
end

function s = varyingTag(isVarying)
    if isVarying, s = 'varying'; else, s = 'uniform'; end
end

function s = classifyInputRole(index, arg)
%CLASSIFYINPUTROLE Human-readable note per input.
    if index <= 3
        s = '(bound to R/G/B of input array)';
    elseif arg.HasDefault
        s = '(defaulted in CTL; override optional)';
    elseif strcmp(arg.Name, 'aIn') && arg.Varying
        s = '(auto-defaults to 1.0; override with aIn=<value>)';
    else
        s = '(required; pass as Name=Value)';
    end
end
