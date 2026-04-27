function writeBadge(fileName, payload)
% WRITEBADGE  Serialize PAYLOAD as pretty-printed JSON into
% reports/badge/FILENAME, creating the directory if needed. Shared
% by the three generate*Badge.m wrappers in the parent folder; lives
% here so MATLAB's private-function rule auto-resolves it for those
% callers without exporting it to the path.
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0
    dir = fullfile('reports', 'badge');
    if ~isfolder(dir), mkdir(dir); end
    out = fullfile(dir, fileName);
    fid = fopen(out, 'w');
    c   = onCleanup(@() fclose(fid));
    fprintf(fid, '%s', jsonencode(payload, PrettyPrint=true));
    fprintf('wrote %s\n', out);
end
