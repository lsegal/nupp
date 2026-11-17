local fixture = require("helpers.templatefixture")

local M = {}

function M.theAppTemplateChecks()
    fixture.scaffoldChecks("app", "greeter")
end

function M.theAppTemplateBuilds()
    fixture.scaffoldBuilds("app", "greeter")
end

function M.theAppTemplatePassesItsTests()
    fixture.scaffoldTests("app", "greeter")
end

function M.theAppTemplateRuns()
    fixture.scaffoldRuns("app", "greeter", "Hello, world!")
end

return M
