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

-- The test runner releases the arenas between cases, so every case but a worker's
-- first runs after a release. Leaving them without a metatable afterwards made them
-- strong for the rest of the process: every case after the first saw nothing let go
-- of, and the case above kept all 101 types it built. Which case ran first in its
-- process depended on how each platform's lanes sliced the suite, so it failed on
-- Windows and macOS only (#316).
function M.arenasStayWeakAfterARelease()
    types.releaseUnreferenced()
    types.settle()
    local before = arenaSize()
    local function build()
        local members = {}
        for index = 1, 50 do
            members[index] = types.array(types.literal("issue-316-released-" .. index))
        end

        return types.union(members)
    end
    local id = build().id
    test.truthy(arenaSize() > before, "building the union interned something")
    types.settle()
    test.eq(arenaSize(), before, "a release left the arenas holding what nothing references")
    test.eq(build().id, id, "the same structure built again has the same id")
end

-- Something still holding a type keeps it interned: building the same structure
-- again finds that object rather than making a second one.
function M.referencedTypesStayInterned()
    local held = types.array(types.literal("issue-271-held"))
    types.settle()
    test.truthy(types.array(types.literal("issue-271-held")) == held, "a held type was interned twice")
end

-- A compiled trace keeps what it was recorded against alive where no collection
-- can see it, so settling has to throw the traces away first. With the JIT off
-- there is no trace and this passes either way.
function M.settleLetsGoOfWhatATraceWasRecordedAgainst()
    types.settle()
    local before = arenaSize()
    local function anchor()
        local traced = types.array(types.literal("issue-312-traced"))
        local function get()
            return traced
        end
        local hits = 0
        for _ = 1, 1000 do
            if get() == traced then
                hits = hits + 1
            end
        end

        return hits
    end
    test.eq(anchor(), 1000)
    types.settle()
    test.eq(arenaSize(), before, "a type only a trace referenced stayed interned")
end

-- An interned function keeps lists of its own. Sharing the caller's made what it
-- shared depend on which build of it survived, and so on when the collector ran.
function M.functionTypesDoNotKeepTheCallersLists()
    local params = {types.literal("issue-312-param")}
    local rets = {types.literal("issue-312-ret")}
    local fn = types.func(params, rets)
    test.truthy(fn.params ~= params, "the function kept the caller's parameter list")
    test.truthy(fn.rets ~= rets, "the function kept the caller's result list")
    test.truthy(fn.params[1] == params[1] and #fn.params == 1, "the parameters were copied")
    test.truthy(fn.rets[1] == rets[1] and #fn.rets == 1, "the results were copied")
end

return M
