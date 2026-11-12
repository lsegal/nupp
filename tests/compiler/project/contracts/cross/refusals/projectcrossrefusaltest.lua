local fixture = require("helpers.projectfixture")
local testAssert = fixture.testAssert
local project = fixture.project
local hash = fixture.hash
local nativeStage = fixture.nativeStage
local json = fixture.json
local write = fixture.write
local read = fixture.read
local exists = fixture.exists
local tempProject = fixture.tempProject
local remove = fixture.remove
local syntheticStub = fixture.syntheticStub

local M = {}

function M.crossTargetBuildRefusesSidecarOnlyProvidersBeforeCargoRuns()
    local dir = tempProject({})
    -- The AOT runtime lives only in the Rust provider, and this machine's copy
    -- cannot sit beside a foreign executable.
    local outputs, err = nativeStage.build(dir, "out", {["native.aot_runtime"] = true}, "x86_64-pc-windows-msvc")
    testAssert.eq(outputs, nil, "a compiler-host provider sidecar is not staged")
    assert(err:find("sidecar-only native feature aot_runtime", 1, true), err)
    remove(dir)
end

function M.crossTargetHttpAndUriNeedNoSidecar()
    local dir = tempProject({})
    -- The HTTP client and the URI parser it requires are Nupp, so a foreign
    -- target takes them with no provider artifact at all.
    local outputs, err = nativeStage.build(dir, "out", {["native.http"] = true, ["native.uri"] = true},
        "x86_64-pc-windows-msvc")
    assert(outputs, err)
    for path in pairs(outputs) do
        assert(not path:find("nupp_native", 1, true), "a provider sidecar was staged: " .. path)
    end
    remove(dir)
end

return M
