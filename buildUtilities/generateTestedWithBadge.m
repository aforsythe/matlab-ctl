function generateTestedWithBadge(releases)
% GENERATETESTEDWITHBADGE  Write a shields.io endpoint JSON listing
% MATLAB releases the CI pipeline runs against.
%
%   generateTestedWithBadge(releases) writes
%   reports/badge/tested_with.json with a shields.io endpoint
%   payload whose message joins RELEASES with " | " (e.g.
%   "R2023b | R2024b | R2025b"), for rendering a "MATLAB versions
%   tested" badge on README.md.
%
%   INPUTS:
%       releases - 1xN string array of MATLAB release tags
%                  (e.g. ["R2023b","R2024b","R2025b"])
%
%   OUTPUTS:
%       (writes reports/badge/tested_with.json)
%
%   EXAMPLE:
%       generateTestedWithBadge(["R2024b","R2025b"])
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

    arguments
        releases (1,:) string {mustBeNonempty}
    end

    writeBadge('tested_with.json', struct( ...
        'schemaVersion', 1, ...
        'label',   'MATLAB', ...
        'message', char(strjoin(releases, ' | ')), ...
        'color',   'blue'));
end

function writeBadge(fileName, payload)
%WRITEBADGE Serialize PAYLOAD as pretty-printed JSON into
% reports/badge/FILENAME, creating the directory if needed.
    dir = fullfile('reports', 'badge');
    if ~isfolder(dir), mkdir(dir); end
    out = fullfile(dir, fileName);
    fid = fopen(out, 'w');
    c   = onCleanup(@() fclose(fid));
    fprintf(fid, '%s', jsonencode(payload, PrettyPrint=true));
    fprintf('wrote %s\n', out);
end
