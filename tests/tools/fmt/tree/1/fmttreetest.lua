local fixture = require("helpers.formattree")
local checkPart = fixture.checkPart

local M = {}

function M.everySourceIsFormattedPart1()
    checkPart(1)
end

function M.everySourceIsFormattedPart5()
    checkPart(5)
end

function M.everySourceIsFormattedPart9()
    checkPart(9)
end

function M.everySourceIsFormattedPart13()
    checkPart(13)
end

return M
