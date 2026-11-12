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
    -- The client is Nupp; the URI handling its closure carries is what needs
    -- the sidecar.
    local outputs, err = nativeStage.build(dir, "out", {["native.http"] = true, ["native.uri"] = true},
        "x86_64-pc-windows-msvc")
    testAssert.eq(outputs, nil, "a compiler-host HTTP sidecar is not staged")
    assert(err:find("sidecar-only native feature uri", 1, true), err)
    remove(dir)
end

return M
