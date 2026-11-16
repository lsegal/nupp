local fixture = require("helpers.formattree")
local checkPart = fixture.checkPart

local M = {}

function M.everySourceIsFormattedPart2()
    checkPart(2)
end

function M.everySourceIsFormattedPart6()
    checkPart(6)
end

function M.everySourceIsFormattedPart10()
    checkPart(10)
end

function M.everySourceIsFormattedPart14()
    checkPart(14)
end

return M
