function varargout = apply_ctl_cache_info()
% APPLY_CTL_CACHE_INFO  List cached CTL interpreters in the MEX.
%
%   apply_ctl_cache_info prints a table of every CTL path the MEX
%   has loaded this session, with the mtime the interpreter was
%   cached against. Useful for debugging "did my CTL edit pick up?"
%   (if the on-disk mtime differs from what's cached here, the next
%   apply_ctl call will reload).
%
%   info = apply_ctl_cache_info returns the same data as a 1xN
%   struct array instead of printing.
%
%   INPUTS: (none)
%
%   OUTPUTS (optional):
%       info - Struct array with fields:
%                Path       (char) absolute path to the .ctl file
%                MtimeSec   (double) mtime at load, seconds
%                MtimeNsec  (double) mtime at load, nanoseconds
%
%   EXAMPLE:
%       >> apply_ctl_cache_info
%       >> info = apply_ctl_cache_info;
%       >> isfile(info(1).Path)      % still on disk?
%
%   NOTES:
%       The cache is process-scoped. `clear mex` drops it.
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

    info = apply_ctl_mex('cache-info');
    if nargout == 0
        printCacheInfo(info);
    else
        varargout{1} = info;
    end
end

function printCacheInfo(info)
    if isempty(info)
        fprintf('apply_ctl cache: empty\n');
        return;
    end
    fprintf('apply_ctl cache (%d entries):\n', numel(info));
    for i = 1:numel(info)
        t = datetime(info(i).MtimeSec, ...
                     ConvertFrom='posixtime', TimeZone='local');
        fprintf('  %s\n', info(i).Path);
        fprintf('    cached mtime: %s\n', ...
                char(t + seconds(info(i).MtimeNsec / 1e9)));
    end
end
