function generateCoverageBadge(coverageFile)
% GENERATECOVERAGEBADGE  Write a shields.io endpoint JSON for line
% coverage.
%
%   generateCoverageBadge(coverageFile) parses COVERAGEFILE (a
%   Cobertura XML report produced by `buildtool test`) and writes
%   reports/badge/coverage.json in the shields.io "endpoint" schema,
%   with a label/message pair that README.md's shields URL renders
%   into a coverage badge.
%
%   INPUTS:
%       coverageFile - Path to Cobertura XML file
%
%   OUTPUTS:
%       (writes reports/badge/coverage.json)
%
%   EXAMPLE:
%       generateCoverageBadge('reports/coverage.xml')
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

    arguments
        coverageFile (1,1) string {mustBeFile}
    end

    pct = parseLineRatePct(coverageFile);

    % shields.io color ramp, coarse enough that a run that
    % marginally drops 1% doesn't change badge color.
    if     pct >= 90, color = "brightgreen";
    elseif pct >= 80, color = "green";
    elseif pct >= 70, color = "yellowgreen";
    elseif pct >= 60, color = "yellow";
    elseif pct >= 50, color = "orange";
    else,             color = "red";
    end

    writeBadge('coverage.json', struct( ...
        'schemaVersion', 1, ...
        'label',   'coverage', ...
        'message', sprintf('%.1f%%', pct), ...
        'color',   color));
end

function pct = parseLineRatePct(xmlFile)
%PARSELINERATEPCT Read the line-rate attribute of the root <coverage>
% element from a Cobertura XML file and return it as a percentage.
    txt  = fileread(xmlFile);
    toks = regexp(txt, 'line-rate="([0-9.]+)"', 'tokens', 'once');
    if isempty(toks)
        warning('matlabctl:badge', ...
                'no line-rate attribute in %s; reporting 0%%', xmlFile);
        pct = 0;
    else
        pct = 100 * str2double(toks{1});
    end
end
