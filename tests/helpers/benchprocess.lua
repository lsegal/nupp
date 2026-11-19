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

-- What `debug.bench` reaches that the compiler does not carry. A project that
-- compiles a benchmark from source includes these copies rather than the whole of
-- `src`: with `src` included, every standard-library module the program reaches
-- resolves to a project file there and is checked again in each process instead
-- of shared from the carried copy (#410).
local UNCARRIED = {"debug/bench.nupp", "nupp/bench/internal/record.nupp", "nupp/bench/internal/statistics.nupp",}

local function copyUncarried(directory)
    for _, relative in ipairs(UNCARRIED) do
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
-- every child. One store for the run pays that once: the shared build fills it,
-- and each child that compiles a fixture from source finds `debug.bench` and
-- everything beneath it there (#438).
local function store()
    return require("helpers.commandcache").dir("bench")
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
local programIdentity

-- Every program the suites run, built together: one build per run rather than one
-- per program, which is what a cold run spends nearly all of these suites' time on.
local PROGRAMS = {"bench_fixed_records", "bench_protocol", "bench_suite"}

local function benchmarkProgram(name)
    local fingerprint = require("nupp.compiler.project.fingerprint")
    local digest = require("nupp.compiler.hostservices").hash.digest
    if not programIdentity then
        local root = assert(HERE:match("^(.*)/[^/]+$"))
        local env = require("nupp.compiler.project.env")
        local sources = env.listSourceFiles(env.new(root))
        assert(#sources > 100, "benchmark fixture key must cover the real project sources")
        table.sort(sources)
        local parts = {
            "benchmark-program-v2",
            fingerprint.graphFingerprint(digest),
            digest(read(root .. "/scripts/toolchain.pins")),
            digest(read(HERE .. "/helpers/benchprocess.lua")),
            digest(read(NUPP)),
            _VERSION,
            jit and (jit.version .. jit.os .. jit.arch) or "native",
        }
        for _, path in ipairs(sources) do
            parts[#parts + 1] = path .. "\0" .. digest(read(path))
        end
        for _, variable in ipairs({"NUPP_VM_BINARY", "NUPP_VM_CLI_IMAGE", "NUPP_NATIVE_LIBRARY"}) do
            local path = os.getenv(variable)
            if path and path ~= "" then
                parts[#parts + 1] = digest(read(path))
            end
        end
        local host = rawget(_G, "__NUPP_EXECUTABLE")
        if host then
            parts[#parts + 1] = digest(read(host))
        end
        local pipe = assert(io.popen("env -0"))
        local environment = pipe:read("*a")
        pipe:close()
        local values = {}
        for value in environment:gmatch("[^%z]+") do
            -- Content-validated compiler stores do not change the artifact.
            if not value:match("^NUPP_CACHE_DIR=") then
                values[#values + 1] = value
            end
        end
        table.sort(values)
        parts[#parts + 1] = table.concat(values, "\0")
        programIdentity = digest(table.concat(parts, "\0"))
    end
    local sources = {}
    for index, program in ipairs(PROGRAMS) do
        sources[index] = program .. "\0" .. read(HERE .. "/fixtures/" .. program .. ".nupp")
    end
    local key = "benchmark-programs-" .. digest(programIdentity .. "\0" .. table.concat(sources, "\0"))
    local directory, artifacts, reused = testAssert.suite.fixture(key, function(directory)
        assert(os.execute(("mkdir -p %q %q"):format(directory .. "/src", directory .. "/bench")) == 0)
        local entries, files = {}, {}
        for index, program in ipairs(PROGRAMS) do
            local file = assert(io.open(directory .. "/src/" .. program .. ".nupp", "wb"))
            file:write(read(HERE .. "/fixtures/" .. program .. ".nupp"))
            file:close()
            entries[index], files[index] = ("%q"):format(program), ("%q"):format("src/" .. program .. ".nupp")
        end
        copyUncarried(directory .. "/bench")
        local file = assert(io.open(directory .. "/nupp.lua", "wb"))
        file:write(
            (
                [[return {include = {"src", "bench"}, build = {default = "app", targets = {
app = {kind = "modules", entries = {%s}, sources = {%s}, outDir = "out", optimize = 1}
}}}]]
            ):format(table.concat(entries, ", "), table.concat(files, ", "))
        )
        file:close()
        -- Built by a command rather than in this process, so the check lands in the
        -- store the children read. An environment in this process checks the
        -- standard library again whatever the store holds.
        local pipe = assert(io.popen(inWorkspace(directory, ("%q build 2>&1; echo \"__exit__:$?\""):format(NUPP))))
        local output = pipe:read("*a")
        pipe:close()
        testAssert.eq(output:match("__exit__:(%d+)%s*$"), "0", "build the shared benchmark programs:\n" .. output)
        -- Register the built modules before `nupp run`'s source loader. Native
        -- libraries remain beside them in the ordinary module output tree.
        local preload = {
            [[local source = debug.getinfo(1, "S").source:gsub("\\", "/")
local root = assert(source:match("^@(.*)/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
]]
        }
        for _, path in ipairs(require("nupp.compiler.fs").listFiles(directory .. "/out")) do
            local relative = path:sub(#directory + #"/out/" + 1)
            if relative:match("%.lua$") then
                local module = relative:gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
                preload[
                    #preload + 1
                ] = (
                    "if package.loaded[%q] == nil then package.preload[%q] = assert(loadfile(root .. %q)) end\n"
                ):format(module, module, "/" .. relative)
            end
        end
        local published = {}
        for _, program in ipairs(PROGRAMS) do
            local artifact = "out/" .. program .. ".benchmark.lua"
            file = assert(io.open(directory .. "/" .. artifact, "wb"))
            file:write(table.concat(preload), ("assert(loadfile(root .. %q))()\n"):format("/" .. program .. ".lua"))
            file:close()
            published[program] = artifact
        end

        return published
    end)
    testAssert.suite.work("benchmark.program.builds", reused and 0 or 1)
    local artifact = assert(artifacts[name], "no shared benchmark program is named " .. name)

    return require("nupp.compiler.fs").absolute(directory .. "/" .. artifact)
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
