local fixture = require("helpers.formattree")
local checkPart = fixture.checkPart

local M = {}

function M.everySourceIsFormattedPart3()
    checkPart(3)
end

function M.everySourceIsFormattedPart7()
    checkPart(7)
end

function M.everySourceIsFormattedPart11()
    checkPart(11)
end

function M.everySourceIsFormattedPart15()
    checkPart(15)
end

return M
