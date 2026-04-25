function plan = buildfile
% BUILDFILE  Build plan for the matlab-ctl project.
%
%   plan = buildfile returns a buildplan that wires up three tasks
%   against MATLAB's buildtool. Invoke via `buildtool <task>` at the
%   repo root.
%
%   INPUTS: (none)
%
%   OUTPUTS:
%       plan - Buildplan object consumed by buildtool
%
%   TASKS:
%       clean - Delete generated test and coverage reports
%       check - Run static code analysis (codeIssues) on src and tests
%       test  - Run unit tests with JUnit + Cobertura coverage output,
%               written to reports/. Depends on `check`.
%
%   REQUIRES:
%       MATLAB R2023b or later (for buildtool). The apply_ctl MEX
%       itself runs on R2018a+; this buildfile only drives the
%       MATLAB-side check + test suite.
%
%   EXAMPLE:
%       >> buildtool          % default tasks: check, test
%       >> buildtool test
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
    plan("test").Dependencies = "check";
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
% Run unit tests with coverage
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

    srcFiles = dir(fullfile("src", "**", "*.m"));
    srcFiles = string(arrayfun(@(f) fullfile(f.folder, f.name), ...
        srcFiles, UniformOutput=false));
    if ~isempty(srcFiles)
        runner.addPlugin(CodeCoveragePlugin.forFile(srcFiles, ...
            "Producing", ...
            CoberturaFormat(fullfile("reports", "coverage.xml"))));
    end

    result = runner.run(suite);

    coverageXml = fullfile("reports", "coverage.xml");
    if isfile(coverageXml)
        generateCoverageBadge(coverageXml);
    end

    assertSuccess(result);
end
