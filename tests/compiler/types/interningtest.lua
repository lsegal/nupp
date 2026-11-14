local test = require("assert")
local types = require("nupp.compiler.types")

local HERE = require("helpers.paths").absoluteTests
local ROOT = HERE .. "/.."

local M = {}

-- How many entries the arenas hold right now.
local function arenaSize()
    local count = 0
    for _, entries in pairs(types.identity().arenas) do
        for _ in pairs(entries) do
            count = count + 1
        end
    end

    return count
end

-- Runs `source` in a fresh process with the compiler on its path and returns what
-- it printed. A fresh process is the point: it starts from an arena that has built
-- nothing the source did not ask for, in the order the source asks for it.
local function runFresh(source)
    local script = os.tmpname()
    local file = assert(io.open(script, "wb"))
    file:write(source)
    file:close()
    local pipe = assert(
        io.popen(
            ("NUPP_COMPILER_ROOT='%s' LUA_PATH='%s' luajit '%s' 2>&1"):format(ROOT, package.path, script)
        )
    )
    local out = pipe:read("*a")
    pipe:close()
    os.remove(script)

    return out
end

-- Union members that agree on tag and carry no name used to fall back on the
-- serial each was stamped with, which says only which one the process built first.
-- Two processes that built the same two arrays in opposite orders then rendered
-- one union two ways, and anything generated from it differed with them.
--
-- The functions mention a record, and the second process numbers more records
-- before it. An id spells a record by that number, so ordering on ids alone kept
-- the self-hosting fixpoint's two stages from agreeing on a record's overloads.
function M.unionOrderDoesNotDependOnConstructionOrder()
    local template = [[
local types = require("nupp.compiler.types")
for index = 1, %d do
    types.nominal("Earlier" .. index, "record")
end
local subject = types.nominal("Subject", "record")
local function member(name)
    return types.array(types.literal("issue-271-" .. name))
end
local function overload(name)
    return types.func({subject, types.literal("issue-271-" .. name)}, {types.string})
end
local first, second = "%s", "%s"
local built, overloads = {}, {}
built[first], overloads[first] = member(first), overload(first)
built[second], overloads[second] = member(second), overload(second)
print("union: " .. types.tostring(types.union({built.a, built.b})))
print("intersection: " .. types.tostring(types.intersection({built.a, built.b})))
print("overloads: " .. types.tostring(types.intersection({overloads.a, overloads.b})))
]]
    local forward = runFresh(template:format(0, "a", "b"))
    local reverse = runFresh(template:format(2, "b", "a"))
    test.truthy(forward:find("overloads: ", 1, true), "the probe ran:\n" .. forward)
    test.eq(reverse, forward, "building the members another way reordered them")
end

-- The arenas keep only what something else still references. A type nothing
-- holds is let go of, and building it again gives a new object with the same id,
-- so a key spelled from that id, and every order that breaks ties on it, are the
-- same as before it was collected.
function M.unreferencedTypesAreReleasedAndRebuiltAlike()
    types.settle()
    local before = arenaSize()
    local function build()
        local members = {}
        for index = 1, 50 do
            members[index] = types.array(types.literal("issue-271-released-" .. index))
        end

        return types.union(members)
    end
    local id = build().id
    test.truthy(arenaSize() > before, "building the union interned something")
    types.settle()
    test.eq(arenaSize(), before, "the arenas let go of everything nothing references")
    test.eq(build().id, id, "the same structure built again has the same id")
end

-- Something still holding a type keeps it interned: building the same structure
-- again finds that object rather than making a second one.
function M.referencedTypesStayInterned()
    local held = types.array(types.literal("issue-271-held"))
    types.settle()
    test.truthy(types.array(types.literal("issue-271-held")) == held, "a held type was interned twice")
end

return M
