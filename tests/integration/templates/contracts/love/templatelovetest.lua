local fixture = require("helpers.templatefixture")

local M = {}

-- LÖVE owns the event loop, so its host integration is not part of this
-- headless suite. The template's game logic and generated module tree are, and
-- they are checked against the LuaCATS revision the template pins, fetched as
-- `nupp init love` fetches it, so a pin this compiler cannot read fails here.

function M.theLoveTemplateChecks()
    fixture.scaffoldChecks("love", "sample-love")
end

function M.theLoveTemplateBuilds()
    fixture.scaffoldBuilds("love", "sample-love")
end

function M.theLoveTemplatePassesItsTests()
    fixture.scaffoldTests("love", "sample-love")
end

return M
