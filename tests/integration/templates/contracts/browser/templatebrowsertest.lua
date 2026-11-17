local fixture = require("helpers.templatefixture")
local withDevelopmentRocks = fixture.withDevelopmentRocks

local M = {}

-- The application itself is exercised in the Wasm browser acceptance lane.
-- Here the built-in promise is that a generated project reaches its checked,
-- dependency-backed Lua 5.1 bundle without needing Emscripten.

function M.theBrowserTemplateChecks()
    fixture.scaffoldChecks("browser", "sample-browser", withDevelopmentRocks)
end

function M.theBrowserTemplateBuilds()
    fixture.scaffoldBuilds("browser", "sample-browser", withDevelopmentRocks)
end

function M.theBrowserTemplatePassesItsTests()
    fixture.scaffoldTests("browser", "sample-browser", withDevelopmentRocks)
end

return M
