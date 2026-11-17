local fixture = require("helpers.templatefixture")

local M = {}

-- No `run`: a library has no entry point, and its test is what exercises it.

function M.theLibTemplateChecks()
    fixture.scaffoldChecks("lib", "sample-lib")
end

function M.theLibTemplateBuilds()
    fixture.scaffoldBuilds("lib", "sample-lib")
end

function M.theLibTemplatePassesItsTests()
    fixture.scaffoldTests("lib", "sample-lib")
end

return M
