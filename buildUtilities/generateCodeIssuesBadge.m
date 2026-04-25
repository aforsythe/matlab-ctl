function generateCodeIssuesBadge(issues)
% GENERATECODEISSUESBADGE  Write a shields.io endpoint JSON summarizing
% MATLAB code-analysis output.
%
%   generateCodeIssuesBadge(issues) writes
%   reports/badge/code_issues.json with a shields.io endpoint payload
%   whose message is the count of static-analysis issues (from
%   `codeIssues(...)`), and whose color turns red on any issue, green
%   when clean. The badge keeps CI visibility on the static analysis
%   step.
%
%   INPUTS:
%       issues - The Issues table from a codeIssues(...) call, or any
%                empty value when analysis reports no issues.
%
%   OUTPUTS:
%       (writes reports/badge/code_issues.json)
%
%   EXAMPLE:
%       results = codeIssues(["src","tests"]);
%       generateCodeIssuesBadge(results.Issues);
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

    if isempty(issues)
        count = 0;
    else
        count = height(issues);
    end

    if count == 0
        color = 'brightgreen';
        msg   = '0 issues';
    elseif count <= 5
        color = 'yellow';
        msg   = sprintf('%d issues', count);
    else
        color = 'red';
        msg   = sprintf('%d issues', count);
    end

    writeBadge('code_issues.json', struct( ...
        'schemaVersion', 1, ...
        'label',   'code issues', ...
        'message', msg, ...
        'color',   color));
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
