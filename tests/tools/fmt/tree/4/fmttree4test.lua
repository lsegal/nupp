local fixture = require("helpers.formattree")
local checkPart = fixture.checkPart

local M = {}

function M.everySourceIsFormattedPart4()
    checkPart(4)
end

function M.everySourceIsFormattedPart8()
    checkPart(8)
end

function M.everySourceIsFormattedPart12()
    checkPart(12)
end

function M.everySourceIsFormattedPart16()
    checkPart(16)
end

return M
