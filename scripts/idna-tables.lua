-- Writes src/nupp/io/uri/idnatables.nupp from the Unicode Character Database.
--
--   luajit scripts/idna-tables.lua VERSION DIRECTORY OUTPUT
--
-- DIRECTORY holds IdnaMappingTable.txt, UnicodeData.txt,
-- DerivedNormalizationProps.txt, DerivedBidiClass.txt and
-- DerivedJoiningType.txt for VERSION; scripts/idna-tables fetches them. Each
-- table is run-length text, decoded once by nupp.io.uri.idna the first time a
-- host needs IDNA, so the module costs a few string constants until then.
local version, directory, output = arg[1], arg[2], arg[3]
assert(version and directory and output, "usage: luajit scripts/idna-tables.lua VERSION DIRECTORY OUTPUT")

local LAST = 0x10FFFF

local function lines(name)
    local file = assert(io.open(directory .. "/" .. name, "rb"))
    local text = file:read("*a")
    file:close()
    return text:gmatch("([^\n]*)\n")
end

local function range(field)
    local first, last = field:match("^%s*(%x+)%.%.(%x+)%s*$")
    if first then
        return tonumber(first, 16), tonumber(last, 16)
    end
    local only = tonumber(field:match("^%s*(%x+)%s*$"), 16)
    return only, only
end

local function hex(value)
    return ("%x"):format(value)
end

-- Run-length text for a per-code-point array of string values: each run is its
-- length in lowercase hexadecimal followed by its value, which must not start
-- with a hexadecimal digit.
local function runs(values)
    local out, start = {}, 0
    for cp = 1, LAST + 1 do
        if cp > LAST or values[cp] ~= values[start] then
            out[#out + 1] = hex(cp - start) .. values[start]
            start = cp
        end
    end
    return table.concat(out)
end

-- The UTS #46 mapping, non-transitional: a deviation is valid. A run of mapped
-- code points that each map to one code point a fixed distance away is one
-- offset run, which is how case pairs and the mathematical alphabets stay small.
local status, target = {}, {}
for line in lines("IdnaMappingTable.txt") do
    local body = line:gsub("#.*", "")
    if body:find("%S") then
        local fields = {}
        for field in (body .. ";"):gmatch("([^;]*);") do
            fields[#fields + 1] = field:match("^%s*(.-)%s*$")
        end
        local first, last = range(fields[1])
        local kind = fields[2]
        if kind == "deviation" then
            kind = "valid"
        end
        assert(
            kind == "valid" or kind == "mapped" or kind == "ignored" or kind == "disallowed",
            "unknown status " .. kind
        )
        local mapping
        if kind == "mapped" then
            mapping = {}
            for value in fields[3]:gmatch("%x+") do
                mapping[#mapping + 1] = tonumber(value, 16)
            end
        end
        for cp = first, last do
            status[cp], target[cp] = kind, mapping
        end
    end
end
for cp = 0, LAST do
    assert(status[cp], ("U+%04X has no UTS #46 status"):format(cp))
end

local mapping = {}
do
    local cp = 0
    while cp <= LAST do
        local kind, length, value = status[cp], 1, nil
        if kind == "mapped" and #target[cp] == 1 then
            local offset = target[cp][1] - cp
            while cp + length <= LAST
                and status[cp + length] == "mapped"
                and #target[cp + length] == 1
                and target[cp + length][1] - (cp + length) == offset do
                length = length + 1
            end
            value = "O" .. (offset < 0 and "-" or "+") .. hex(math.abs(offset))
        elseif kind == "mapped" then
            local spelled = {}
            for index, point in ipairs(target[cp]) do
                spelled[index] = hex(point)
            end
            value = "M" .. table.concat(spelled, ",")
            while cp + length <= LAST
                and status[cp + length] == "mapped"
                and table.concat(target[cp + length], ",") == table.concat(target[cp], ",") do
                length = length + 1
            end
        else
            while cp + length <= LAST and status[cp + length] == kind do
                length = length + 1
            end
            value = ({valid = "V", ignored = "I", disallowed = "D"})[kind]
        end
        mapping[#mapping + 1] = hex(length) .. value .. ";"
        cp = cp + length
    end
end

-- Canonical decompositions, combining classes and general categories.
local decomposition, combining, mark = {}, {}, {}
do
    local pendingFirst
    for line in lines("UnicodeData.txt") do
        local fields = {}
        for field in (line .. ";"):gmatch("([^;]*);") do
            fields[#fields + 1] = field
        end
        local cp = tonumber(fields[1], 16)
        local name, category, class = fields[2], fields[3], tonumber(fields[4])
        local first = cp
        if name:find(", First>$") then
            pendingFirst = cp
        else
            if name:find(", Last>$") then
                first = pendingFirst
            end
            for point = first, cp do
                combining[point] = class
                mark[point] = category == "Mn" or category == "Mc" or category == "Me"
            end
            if fields[6] ~= "" and not fields[6]:find("<") then
                local parts = {}
                for value in fields[6]:gmatch("%x+") do
                    parts[#parts + 1] = tonumber(value, 16)
                end
                decomposition[cp] = parts
            end
        end
    end
end

local excluded = {}
for line in lines("DerivedNormalizationProps.txt") do
    local field = line:match("^([%x.]+)%s*;%s*Full_Composition_Exclusion%s")
    if field then
        local first, last = range(field)
        for cp = first, last do
            excluded[cp] = true
        end
    end
end

local function decompose(cp, out)
    local parts = decomposition[cp]
    if parts == nil then
        out[#out + 1] = cp
        return out
    end
    for _, part in ipairs(parts) do
        decompose(part, out)
    end
    return out
end

local decompositions, compositions = {}, {}
do
    local points = {}
    for cp in pairs(decomposition) do
        points[#points + 1] = cp
    end
    table.sort(points)
    local previous = 0
    for _, cp in ipairs(points) do
        local spelled = {}
        for index, point in ipairs(decompose(cp, {})) do
            spelled[index] = hex(point)
        end
        decompositions[#decompositions + 1] = hex(cp - previous) .. "=" .. table.concat(spelled, ",") .. ";"
        previous = cp
        local parts = decomposition[cp]
        if #parts == 2 and not excluded[cp] then
            compositions[#compositions + 1] = hex(parts[1]) .. "," .. hex(parts[2]) .. "=" .. hex(cp) .. ";"
        end
    end
end

local classes, marks = {}, {}
for cp = 0, LAST do
    local class = combining[cp] or 0
    classes[cp] = ":" .. hex(class) .. ";"
    marks[cp] = mark[cp] and "M" or "N"
end

-- Bidi classes, with the defaults the file's @missing lines give unassigned
-- code points. IDNA reads only these; every other class is X.
local BIDI = {
    Left_To_Right = "L",
    Right_To_Left = "R",
    Arabic_Letter = "A",
    Arabic_Number = "N",
    European_Number = "E",
    European_Separator = "S",
    Common_Separator = "C",
    European_Terminator = "T",
    Other_Neutral = "O",
    Boundary_Neutral = "B",
    Nonspacing_Mark = "M",
    L = "L",
    R = "R",
    AL = "A",
    AN = "N",
    EN = "E",
    ES = "S",
    CS = "C",
    ET = "T",
    ON = "O",
    BN = "B",
    NSM = "M",
}
local bidi = {}
for line in lines("DerivedBidiClass.txt") do
    local missing, missingClass = line:match("^# @missing: ([%x.]+); (%S+)")
    local field, class = line:match("^([%x.]+)%s*;%s*(%S+)")
    field, class = field or missing, class or missingClass
    if field then
        local first, last = range(field)
        for cp = first, last do
            bidi[cp] = BIDI[class] or "X"
        end
    end
end

local joining = {}
for cp = 0, LAST do
    joining[cp] = "U"
end
for line in lines("DerivedJoiningType.txt") do
    local field, kind = line:match("^([%x.]+)%s*;%s*(%a)")
    if field then
        assert(("DLRTCU"):find(kind, 1, true), "unknown joining type " .. kind)
        local first, last = range(field)
        for cp = first, last do
            joining[cp] = kind
        end
    end
end

-- Long strings broken into lines; the decoder skips whitespace.
local function block(text)
    local out = {}
    for index = 1, #text, 100 do
        out[#out + 1] = text:sub(index, index + 99)
    end
    local joined = table.concat(out, "\n")
    assert(not joined:find("]]", 1, true))
    return "[[\n" .. joined .. "]]"
end

local file = assert(io.open(output, "wb"))
file:write(([=[
@!internal
--[[
Unicode %s data for [](nupp.io.uri.idna), generated by `scripts/idna-tables`
from the Unicode Character Database. Do not edit it by hand.

Each table is run-length text in lowercase hexadecimal; nupp.io.uri.idna
documents the formats and decodes them the first time a host needs IDNA.
]]
module nupp.io.uri.idnatables

--- The Unicode version every table was generated from.
export const VERSION = "%s"

--- The UTS #46 mapping status of every code point.
export const MAPPING = %s

--- The full canonical decomposition of every code point that has one.
export const DECOMPOSITIONS = %s

--- The canonical compositions, without composition exclusions.
export const COMPOSITIONS = %s

--- The canonical combining class of every code point.
export const COMBINING = %s

--- Which code points are combining marks (Mn, Mc or Me).
export const MARKS = %s

--- The bidi class of every code point, reduced to the classes IDNA reads.
export const BIDI = %s

--- The joining type of every code point.
export const JOINING = %s
]=]):format(
    version,
    version,
    block(table.concat(mapping)),
    block(table.concat(decompositions)),
    block(table.concat(compositions)),
    block(runs(classes)),
    block(runs(marks)),
    block(runs(bidi)),
    block(runs(joining))
))
file:close()
