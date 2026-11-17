local fixture = require("helpers.bundlefixture")
local HERE = fixture.HERE
local packaging = fixture.packaging
local tempProject = fixture.tempProject
local readFile = fixture.readFile

local M = {}

function M.aBootstrapCompilerRetainsPublicRuntimeArtifacts()
    local dir = tempProject({
        ["build/nupp/tools/main.lua"] = 'return _G.__nuppCompilerModuleArtifacts["debug.log"].source',
        ["build/debug/log.lua"] = "return 17",
    })
    local target = {kind = "modules", outDir = "build", entries = {"nupp.tools.main"}}
    local modules = {
        ["nupp.tools.main"] = {output = dir .. "/build/nupp/tools/main.lua"},
        ["debug.log"] = {output = dir .. "/build/debug/log.lua"},
    }
    local text = assert(packaging.bundleText(dir, {}, target, nil, modules))
    local savedArtifacts = rawget(_G, "__nuppCompilerModuleArtifacts")
    local savedMain, savedMainLoaded = package.preload["nupp.tools.main"], package.loaded["nupp.tools.main"]
    local savedLog, savedLogLoaded = package.preload["debug.log"], package.loaded["debug.log"]
    local savedWarn = rawget(_G, "warn")
    package.loaded["nupp.tools.main"] = nil
    local ok, result = pcall(assert(loadstring(text)))
    package.preload["nupp.tools.main"], package.loaded["nupp.tools.main"] = savedMain, savedMainLoaded
    package.preload["debug.log"], package.loaded["debug.log"] = savedLog, savedLogLoaded
    rawset(_G, "warn", savedWarn)
    rawset(_G, "__nuppCompilerModuleArtifacts", savedArtifacts)
    os.execute("rm -rf '" .. dir .. "'")
    assert(ok, result)
    assert(result == "return 17", "a bootstrap compiler can reuse its public runtime without a module directory")
end

function M.aCompilerCarryingPayloadFindsItsModulesFromTheExecutable()
    local dir = tempProject({
        ["build/test-runner/main.lua"] = "return 1",
        ["build/test-runner/nupp/compiler/bundled.lua"] = "return {}",
    })
    local target = {kind = "binary", outDir = "build/test-runner", entries = {"main"}}
    local modules = {
        main = {output = dir .. "/build/test-runner/main.lua"},
        ["nupp.compiler.bundled"] = {output = dir .. "/build/test-runner/nupp/compiler/bundled.lua"},
    }
    local text = assert(packaging.bundleText(dir, {}, target, nil, modules, false, {}, nil, false, nil, "test-runner"))
    local plain = assert(
        packaging.bundleText(dir, {}, target, nil, {main = modules.main}, false, {}, nil, false, nil, "test-runner")
    )
    os.execute("rm -rf '" .. dir .. "'")
    assert(text:find('rawset(_G, "__nuppPayloadModuleRoot", "test-runner")', 1, true), text)
    assert(not plain:find("__nuppPayloadModuleRoot", 1, true), "a payload without the compiler records nothing")

    -- A stamped payload names its chunk for the executable, and a worker state's for
    -- nothing; either way the modules are found from the executable the host names.
    local source = assert(readFile(HERE .. "/../build/nupp/compiler/bundled.lua"))
    local savedRoot, savedExecutable = rawget(_G, "__nuppPayloadModuleRoot"), rawget(_G, "__NUPP_EXECUTABLE")
    rawset(_G, "__nuppPayloadModuleRoot", "test-runner")
    rawset(_G, "__NUPP_EXECUTABLE", "/work/build/nupp-test")
    local function moduleDirAs(chunkName)
        return pcall(function()
            return assert(loadstring(source, chunkName))().moduleDir()
        end)
    end
    local ok, carried = moduleDirAs("@/work/build/nupp-test")
    local okWorker, worker = moduleDirAs("=nupp-worker")
    local okLua, fromFile = moduleDirAs("@/work/build/nupp/compiler/bundled.lua")
    rawset(_G, "__nuppPayloadModuleRoot", savedRoot)
    rawset(_G, "__NUPP_EXECUTABLE", savedExecutable)
    assert(ok, carried)
    assert(okWorker, worker)
    assert(okLua, fromFile)
    assert(carried == "/work/build/test-runner/nupp/compiler", carried)
    assert(worker == "/work/build/test-runner/nupp/compiler", worker)
    assert(fromFile == "/work/build/nupp/compiler", "a module loaded from its file keeps its own directory")
end

function M.compilerHostPreambleMasksUniversalStubFeaturesBeforeUserCode()
    local dir = tempProject({
        [
            "build/main.lua"
        ] = [[
assert(rawget(_G, "__nuppHost") == nil)
local name = "lp" .. "eg"
local loaded = pcall(require, name)
return loaded
]],
    })
    local target = {kind = "binary", outDir = "build", entries = {"main"}}
    local modules = {main = {output = dir .. "/build/main.lua"}}
    local text = assert(packaging.bundleText(dir, {}, target, nil, modules, false, {}, {"workers"}))
    local again = assert(packaging.bundleText(dir, {}, target, nil, modules, false, {}, {"workers"}))
    assert(text == again, "the payload depends on selected features, not ambient stub state")

    -- The names are kept as a list rather than recovered from the saved table,
    -- because a module that was not preloaded saves as nil and `pairs` does not
    -- visit it. Restoring by iteration therefore left this test's stub opener
    -- installed for every later `require` of it.
    local stubbed = {"lpeg", "nupp.workers.native"}
    local savedPreloads, savedLoaded = {}, package.loaded.lpeg
    local savedPath, savedCpath = package.path, package.cpath
    for _, name in ipairs(stubbed) do
        savedPreloads[name] = package.preload[name]
        package.preload[name] = function()
            return name
        end
    end
    package.loaded.lpeg = nil
    package.path, package.cpath = "", ""
    _G.__nuppHost = {hostAbi = 1, hostFeatures = {lpeg = true, workers = true,}}
    local loaded = assert(loadstring(text))()
    assert(not loaded, "a computed require cannot observe an unselected universal feature")
    assert(package.preload["nupp.workers.native"], "selected worker opener remains visible")
    assert(package.preload.lpeg == nil, "unselected universal openers are removed")
    assert(_G.__nuppHost == nil, "the private handshake is gone before user code")
    package.loaded.lpeg = savedLoaded
    package.path, package.cpath = savedPath, savedCpath
    for _, name in ipairs(stubbed) do
        package.preload[name] = savedPreloads[name]
    end
    package.preload["nupp.embedded"] = nil
    os.execute("rm -rf '" .. dir .. "'")
end

-- The compiler's own stage-zero bundle goes through this same code. If the two
-- ever diverge, the bundle a release publishes is being produced by a path
-- nothing else tests. It is fetched rather than tracked, so this asks the
-- toolchain for it the way the launcher does.
function M.theStageZeroIsProducedByTheGeneralBundler()
    local root = HERE .. "/.."
    local handle = assert(io.popen(("'%s/scripts/toolchain' stage0 2>/dev/null"):format(root)))
    local named = handle:read("*a")
    local ok = handle:close()
    assert(ok, "no stage-zero compiler; run scripts/toolchain stage0")
    local stage0 = readFile((named:match("([^\n]+)%s*$")))
    assert(stage0, "the fetched stage zero is readable")
    assert(
        stage0:find('package.preload["nupp.embedded"]', 1, true),
        "it carries its resources the way every bundle does"
    )
    assert(
        stage0:find("package.preload[\"nupp.compiler\"]", 1, true),
        "and preloads its modules the way every bundle does"
    )
end

return M
