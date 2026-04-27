function plan = buildfile
% BUILDFILE  Build plan for the ctl-matlab project.
%
%   plan = buildfile returns a buildplan that wires up four tasks
%   against MATLAB's buildtool. Invoke via `buildtool <task>` at the
%   repo root.
%
%   INPUTS: (none)
%
%   OUTPUTS:
%       plan - Buildplan object consumed by buildtool
%
%   TASKS:
%       clean    - Delete generated test and coverage reports
%       check    - Run static code analysis (codeIssues) on src and tests
%       test     - Run unit tests with JUnit output, written to reports/.
%                  Depends on `check`.
%       coverage - Run unit tests with JUnit + Cobertura coverage output,
%                  written to reports/. Depends on `check`.
%
%   REQUIRES:
%       MATLAB R2023b or later (for buildtool). The apply_ctl MEX
%       itself runs on R2018a+; this buildfile only drives the
%       MATLAB-side check + test suite.
%
%   EXAMPLE:
%       >> buildtool          % default tasks: check, test
%       >> buildtool test
%       >> buildtool coverage
%       >> buildtool clean
%
%   Copyright (c) 2026 Alex Forsythe, Academy of Motion Picture Arts and Sciences
%   SPDX-License-Identifier: Apache-2.0

    % Set up paths (the .prj isn't guaranteed open in CI).
    root = fileparts(mfilename("fullpath"));
    addpath(fullfile(root, "src"));
    addpath(fullfile(root, "buildUtilities"));

    % Auto-discover task functions.
    plan = buildplan(localfunctions);

    % Configure dependencies and defaults.
    plan("test").Dependencies     = "check";
    plan("coverage").Dependencies = "check";
    plan.DefaultTasks = ["check", "test"];
end


function cleanTask(~)
% Delete generated reports
    if isfolder("reports")
        delete(fullfile("reports", "*.xml"));
    end
end


function checkTask(~)
% Run static analysis on src and tests; write the code-issues badge
    results = codeIssues(["src", "tests", "buildUtilities"]);
    if ~isempty(results.Issues)
        disp(results.Issues);
    end
    generateCodeIssuesBadge(results.Issues);
end


function testTask(~)
% Run unit tests, write JUnit XML (no coverage instrumentation)
    runTests(false);
end


function coverageTask(~)
% Run unit tests with Cobertura coverage; write coverage.xml + badge
    runTests(true);
end


function runTests(withCoverage)
    import matlab.unittest.TestRunner
    import matlab.unittest.plugins.CodeCoveragePlugin
    import matlab.unittest.plugins.XMLPlugin
    import matlab.unittest.plugins.codecoverage.CoberturaFormat

    suite  = testsuite("tests");
    runner = TestRunner.withTextOutput;

    if ~isfolder("reports")
        mkdir("reports");
    end

    runner.addPlugin( ...
        XMLPlugin.producingJUnitFormat( ...
            fullfile("reports", "test-results.xml")));

    if withCoverage
        srcFiles = dir(fullfile("src", "**", "*.m"));
        srcFiles = string(arrayfun(@(f) fullfile(f.folder, f.name), ...
            srcFiles, UniformOutput=false));
        if ~isempty(srcFiles)
            runner.addPlugin(CodeCoveragePlugin.forFile(srcFiles, ...
                "Producing", ...
                CoberturaFormat(fullfile("reports", "coverage.xml"))));
        end
    end

    result = runner.run(suite);

    if withCoverage
        coverageXml = fullfile("reports", "coverage.xml");
        if isfile(coverageXml)
            generateCoverageBadge(coverageXml);
        end
    end

    assertSuccess(result);
end
