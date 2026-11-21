local testAssert = require("assert")
-- The `nupp bench` runner, exercised by starting real processes.
--
-- Split out from `benchtest.lua` because of what it costs. Every case here spawns
-- children -- the replicated one starts twelve -- and together they take about three
-- minutes where the rest of the bench surface takes seconds. `tests/groups.lua` names
-- this suite `measurement` and CI runs it only when the classifier says a path reached
-- that surface, which is what keeps three minutes off every unrelated change.
--
-- The division is by cost, not by importance, and the line is drawn so that nothing
-- gated here is the only cover for something an ungated change can break. What stays
-- behind is everything a compiler or library change can reach without touching bench
-- code: the `keep` intrinsic's lowering, the allocation account, the statistics, the
-- fork merge rules and the result table. What moved is the process boundary itself --
-- case listing, selection, replication, the pilot -- which only bench code changes.
--
-- The classifier rules that select this suite are in
-- `.github/scripts/classify-changes.lua`, and
-- `tests/tools/repository/cichangeclassifiertest.lua` asserts that each of its inputs
-- reaches the `measurement` surface. Adding a case here that covers something outside
-- those paths silently loses that cover.
local json = require("testjson")

local HERE = require("helpers.paths").absoluteTests
if HERE:sub(1, 1) ~= "/" and not HERE:match("^%a:[/\\]") then
    local pipe = assert(io.popen("pwd"))
    HERE = assert(pipe:read("*l")) .. "/" .. HERE
    pipe:close()
end
local NUPP = HERE .. "/../bin/nupp"
-- How long each child a case starts may take. The runner's two-minute default is
-- for a person's benchmark; these children compile their fixture cold, twelve at
-- a time in the replicated case, beside every other suite in a full run, and
-- under that load a child listing its cases took longer than two minutes while
-- the same case alone takes seconds. The bound is still there to stop a child
-- that hangs, and none of these cases is about how the default is chosen.
local TIMEOUT_MS = 15 * 60 * 1000
local NUPP_SRC = HERE .. "/../src"

local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()

    return content
end

local function jsonLines(path)
    local values = {}
    for line in read(path):gmatch("[^\r\n]+") do
        values[#values + 1] = json.decode(line)
    end

    return values
end

local programs = require("helpers.benchprograms")

local function copyUncarried(directory)
    for _, relative in ipairs(programs.UNCARRIED) do
        local target = directory .. "/" .. relative
        assert(os.execute(("mkdir -p %q"):format(assert(target:match("^(.*)/[^/]+$")))) == 0)
        local file = assert(io.open(target, "wb"))
        file:write(read(NUPP_SRC .. "/" .. relative))
        file:close()
    end
end

local function workspace(precompiled)
    local directory = os.tmpname()
    os.remove(directory)
    testAssert.eq(os.execute(("mkdir -p %q"):format(directory)), 0, "create isolated benchmark workspace")
    if not precompiled then
        copyUncarried(directory .. "/bench")
    end
    local manifest = assert(io.open(directory .. "/nupp.lua", "wb"))
    manifest:write(("return {include = {%q}}\n"):format(precompiled and "." or "bench"))
    manifest:close()

    return directory
end

-- The store every command these suites start shares. `debug.bench` itself checks
-- in about a second; what a cold command spends its twenty seconds on is the
-- standard library it reaches, which an empty store checks from source again in
-- every child. The build of the benchmark programs fills one store, and each
-- child that compiles a fixture from source finds `debug.bench` and everything
-- beneath it there (#438). Before that build, the run's own `bench` store.
local function store()
    return programs.preparedStore() or require("helpers.commandcache").dir("bench")
end

local function inWorkspace(directory, command)
    return ("cd %q && NUPP_CACHE_DIR=%q %s"):format(directory, store(), command)
end

-- The evidence a `--json` run printed, as the record it saved would hold it: the
-- document on stdout is that record plus `ok` and `diagnostics`, and its keys may come
-- in another order, so the two are compared as values.
local function evidence(text)
    local value = json.decode(text)
    value.ok, value.diagnostics = nil, nil

    local function canonical(item)
        if type(item) ~= "table" then
            return json.encode(item)
        end
        local keys = {}
        for key in pairs(item) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = tostring(key) .. "=" .. canonical(item[key])
        end

        return "{" .. table.concat(parts, ",") .. "}"
    end

    return canonical(value)
end

-- Process orchestration reuses a compiled program. Source compilation remains
-- covered by the standalone protocol tests; every fork still executes its work.
-- The runner builds every program once before any case starts
-- (tests/helpers/benchprograms.lua), so no case waits on that build (#438).
local function benchmarkProgram(name)
    local known = false
    for _, program in ipairs(programs.PROGRAMS) do
        known = known or program == name
    end
    assert(known, "no shared benchmark program is named " .. name)
    local directory = assert(programs.path(assert(HERE:match("^(.*)/[^/]+$"))))

    return directory .. "/project/out/" .. name .. ".benchmark.lua"
end

return {
    testAssert = testAssert,
    json = json,
    HERE = HERE,
    NUPP = NUPP,
    TIMEOUT_MS = TIMEOUT_MS,
    NUPP_SRC = NUPP_SRC,
    read = read,
    jsonLines = jsonLines,
    workspace = workspace,
    benchmarkProgram = benchmarkProgram,
    inWorkspace = inWorkspace,
    evidence = evidence,
}
