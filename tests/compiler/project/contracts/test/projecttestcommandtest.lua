local fixture = require("helpers.projectfixture")
local testAssert = fixture.testAssert
local project = fixture.project
local process = fixture.process
local read = fixture.read
local exists = fixture.exists
local tempProject = fixture.tempProject
local remove = fixture.remove
local json = fixture.json

local M = {}

function M.testCommandBuildsThenRunsArgv()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[
return {
   include = {"src"},
   build = {outDir = "out", entries = {"main"}},
   test = {argv = {"luajit", "test.lua"}},
}
]],
        ["src/main.nupp"] = "return true\n",
        [
            "test.lua"
        ] = [[
assert(os.getenv("NUPP_TEST_BUILD") == "out", tostring(os.getenv("NUPP_TEST_BUILD")))
local f = assert(io.open("test-ran", "wb"))
f:write("yes")
f:close()
]],
    })
    testAssert.eq(project.test(dir), 0)
    testAssert.eq(read(dir .. "/test-ran"), "yes")
    assert(exists(dir .. "/out/main.lua"), "test builds first")
    remove(dir)
end

function M.testOutputOverrideRunsTheArtifactItBuilt()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[
return {
   include = {"src"},
   build = {
      kind = "bundle",
      outDir = "build",
      output = "build/test.lua",
      entries = {"main"},
   },
   test = {argv = {"luajit", "build/test.lua"}},
}
]],
        [
            "src/main.lua"
        ] = [[
assert(os.getenv("NUPP_TEST_BUILD") == "coverage", tostring(os.getenv("NUPP_TEST_BUILD")))
local hostio = rawget(_G, "io")
local file = assert(hostio.open("test-ran", "wb"))
file:write("yes")
file:close()
]],
    })
    testAssert.eq(project.test(dir, {}, {outDir = "coverage"}), 0)
    testAssert.eq(read(dir .. "/test-ran"), "yes")
    assert(exists(dir .. "/coverage/test.lua"), "the override receives the test artifact")
    assert(not exists(dir .. "/build/test.lua"), "the manifest output is not overwritten")
    remove(dir)
end

function M.testCommandDefaultsToBundledRunner()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[
return {
   include = {"src"},
   build = {
      default = "app",
      targets = {app = {outDir = "out", entries = {"main"}}},
   },
   test = {build = "app"},
}
]],
        ["src/main.nupp"] = "return true\n",
    })
    local originalRun = process.run
    local ran
    process.run = function(argv, options)
        ran = {argv = argv, options = options}
        return 0
    end
    local ok, result = pcall(project.test, dir)
    process.run = originalRun
    assert(ok, result)
    testAssert.eq(result, 0)
    testAssert.eq(ran.argv[2], "test", "the default runner stays under the test command")
    testAssert.eq(ran.argv[3], "--internal-runner", "the default test command is Nupp's bundled runner")
    testAssert.eq(ran.options.cwd, dir, "the default runner starts in the project")
    assert(exists(dir .. "/out/main.lua"), "the default test command builds first")
    remove(dir)
end

-- `nupp test` builds in a child so that it holds nothing of the build while it waits
-- on the tests; the build a caller hands in is the one that runs, with the options
-- `project.build` would have had, and its artifact is what the command runs.
function M.testRunsTheBuildTheCallerHandsIn()
    local dir = tempProject({
        ["nupp.lua"] = [[
return {
   include = {"src"},
   build = {kind = "bundle", outDir = "build", output = "build/test.lua", entries = {"main"}},
   test = {argv = {"luajit", "build/test.lua"}},
}
]],
        ["src/main.nupp"] = "return true\n",
        ["elsewhere.lua"] = [[
local f = assert(io.open("test-ran", "wb"))
f:write("yes")
f:close()
]],
    })
    local asked
    local code = project.test(dir, {}, {
        build = function(root, opts)
            asked = {root = root, testBuild = opts.testBuild, target = opts.target}
            opts.produced.artifact = "elsewhere.lua"
            return 0
        end,
        outDir = "elsewhere",
    })
    testAssert.eq(code, 0)
    testAssert.eq(asked.root, dir)
    testAssert.eq(asked.testBuild, true, "the handed-in build is a test build")
    testAssert.eq(read(dir .. "/test-ran"), "yes", "the command runs the artifact the handed-in build made")
    assert(not exists(dir .. "/build/test.lua"), "nothing was built in this process")
    local stopped
    code, stopped = project.test(dir, {}, {build = function() return 1 end})
    testAssert.eq(code, 1)
    testAssert.eq(stopped, "build")
    remove(dir)
end

-- What crosses back from the child is its status, the artifact and the gathered
-- diagnostics, through the request file named after the command it was given.
function M.childTestBuildReadsOnlyTheOutcomeTheChildWrote()
    local dir = tempProject({
        ["child.lua"] = [[
local request = assert(io.open(arg[1], "rb")):read("*a")
assert(request:find('"target":"runner"', 1, true), request)
assert(request:find('"gather":true', 1, true), request)
assert(arg[2] == "--color=never", tostring(arg[2]))
local f = assert(io.open(arg[1], "wb"))
f:write('{"code":0,"artifact":"build/runner","diagnostics":[{"code":"NUPP9999","msg":"kept"}]}')
f:close()
]],
        ["silent.lua"] = "os.exit(0)\n",
    })
    local produced, diagnostics = {}, {}
    local build = project.childTestBuild({"luajit", dir .. "/child.lua"}, {"--color=never"})
    testAssert.eq(build(".", {target = "runner", produced = produced, diagnostics = diagnostics}), 0)
    testAssert.eq(produced.artifact, "build/runner")
    testAssert.eq(#diagnostics, 1)
    testAssert.eq(diagnostics[1].msg, "kept")

    -- A child that exits without answering built nothing that can be tested.
    diagnostics = {}
    testAssert.eq(project.childTestBuild({"luajit", dir .. "/silent.lua"})(".", {diagnostics = diagnostics}), 1)
    testAssert.eq(#diagnostics, 1, "the missing result is reported")
    remove(dir)
end

function M.serveTestBuildAnswersInTheRequestFile()
    local dir = tempProject({
        ["nupp.lua"] = [[
return {
   include = {"src"},
   build = {kind = "bundle", outDir = "build", output = "build/test.lua", entries = {"main"}},
}
]],
        ["src/main.nupp"] = "return true\n",
    })
    local request = os.tmpname()
    fixture.write(request, json.encode({root = dir, gather = true}))
    testAssert.eq(project.serveTestBuild(request), 0)
    local answer = json.decode(read(request))
    testAssert.eq(answer.code, 0)
    assert(tostring(answer.artifact):match("build/test%.lua$"), tostring(answer.artifact))
    assert(exists(dir .. "/build/test.lua"), "the child built the target")

    fixture.write(dir .. "/src/main.nupp", 'local x: integer = "text"\nreturn x\n')
    fixture.write(request, json.encode({root = dir, gather = true}))
    testAssert.eq(project.serveTestBuild(request), 1)
    answer = json.decode(read(request))
    testAssert.eq(answer.code, 1)
    assert(#answer.diagnostics > 0, "a failed build hands back what it gathered")
    os.remove(request)
    remove(dir)
end

function M.completedTestBuildReusesTheArtifactAndChecksItsBytes()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[return {include={"src"}, build={kind="bundle", outDir="out",
            output="out/tests.lua", entries={"main"}, resources={{source="fixture",output="fixture"}}}}]],
        ["src/main.lua"] = "return 17\n",
        ["fixture"] = "first",
    })
    local modules = require("nupp.tools.build.modules")
    local original = modules.session

    local function build()
        local produced = {}
        testAssert.eq(project.build(dir, {testBuild = true, produced = produced}), 0)
        return produced
    end

    local ok, why = pcall(function()
        assert(not build().testBuildReused)
        local first = read(dir .. "/out/tests.lua")
        modules.session = function()
            error("an unchanged test build entered the checker")
        end
        assert(build().testBuildReused)
        modules.session = original
        testAssert.eq(read(dir .. "/out/tests.lua"), first)
        fixture.write(dir .. "/out/tests.lua", "broken")
        assert(not build().testBuildReused)
        testAssert.eq(read(dir .. "/out/tests.lua"), first)
        assert(build().testBuildReused)
        fixture.write(dir .. "/src/main.lua", "return 18\n")
        assert(not build().testBuildReused)
        assert(read(dir .. "/out/tests.lua") ~= first)
        assert(build().testBuildReused)
        fixture.write(dir .. "/fixture", "second")
        assert(not build().testBuildReused)
        assert(build().testBuildReused)
        fixture.write(dir .. "/src/added.lua", "return true\n")
        assert(not build().testBuildReused)
        assert(build().testBuildReused)
        os.remove(dir .. "/src/added.lua")
        assert(not build().testBuildReused)
        assert(build().testBuildReused)
        os.remove(dir .. "/out/main.lua")
        assert(not build().testBuildReused)
        local statePath = dir .. "/out/.nupp-state.json"
        local state = fixture.json.decode(read(statePath))
        state.testBuild.effects = {invalid = {}}
        fixture.write(statePath, fixture.json.encode(state))
        assert(not build().testBuildReused)
    end)
    modules.session = original
    remove(dir)
    assert(ok, why)
end

function M.completedTestBuildRefreshesNativeInputsAndRejectsChangesDuringBuild()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[return {include={"src"}, build={kind="bundle", outDir="out",
            output="out/tests.lua", entries={"main"}}}]],
        ["src/main.lua"] = "return 17\n",
    })
    local stage = require("nupp.tools.build.native")
    local original, version, calls, during = stage.build, "first", 0, false
    stage.build = function(...)
        calls = calls + 1
        local available = select(5, ...)
        assert(
            type(available) == "table" and available[dir .. "/out/main.lua"] == true,
            "native refresh receives the compiled runtime closure on cold and reused builds"
        )
        local outputs, why = original(...)
        if not outputs then
            return nil, why
        end
        local path = dir .. "/out/lib/native-fixture"
        fixture.write(path, version)
        outputs[path] = true
        if during then
            fixture.write(dir .. "/src/main.lua", "return 19\n")
        end

        return outputs
    end

    local function build(coverage)
        local produced = {}
        testAssert.eq(project.build(dir, {testBuild = true, coverage = coverage, produced = produced}), 0)
        return produced
    end

    local ok, why = pcall(function()
        assert(not build().testBuildReused)
        local before = calls
        assert(build().testBuildReused)
        testAssert.eq(calls, before + 1, "a hit still refreshes the native toolchain")
        version = "second"
        assert(not build().testBuildReused)
        assert(build().testBuildReused)
        assert(not build(true).testBuildReused, "coverage executes its own build")
        during = true
        assert(not build().testBuildReused)
        during = false
        assert(not build().testBuildReused, "a changed in-flight input cannot publish a cache entry")
        assert(build().testBuildReused)
    end)
    stage.build = original
    remove(dir)
    assert(ok, why)
end

function M.testBuildReuseSurvivesSeparateCliProcessesAndToolCallIds()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[return {include={"src"}, build={kind="bundle", outDir="out",
            output="out/tests.lua", entries={"main"}}, test={argv={"luajit","out/tests.lua"}}}]],
        ["src/main.lua"] = "print('ok')\n",
    })
    local nupp = require("helpers.paths").root .. "/bin/nupp"

    local function run(id, setting)
        local code, output = process.capture({nupp, "test"}, {
            cwd = dir,
            env = {CODEX_TOOL_CALL_ID = id, NUPP_TEST_REUSE_INPUT = setting}
        })
        testAssert.eq(code, 0, output)
        testAssert.eq((output:gsub("\r\n", "\n")), "ok\n")

        return select(3, require("io.internal.files").stat(dir .. "/out/tests.lua"))
    end

    local ok, why = pcall(function()
        local first = run("first-transport", "first-setting")
        testAssert.eq(
            run("second-transport", "first-setting"),
            first,
            "a separate CLI process reuses the finished artifact"
        )
        assert(run("third-transport", "changed-setting") ~= first, "actual build environment changes still rebuild")
    end)
    remove(dir)
    assert(ok, why)
end

return M
