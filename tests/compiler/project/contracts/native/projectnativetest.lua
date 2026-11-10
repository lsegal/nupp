local fixture = require("helpers.projectfixture")
local testAssert = fixture.testAssert
local process = fixture.process
local nativeStage = fixture.nativeStage
local fs = fixture.fs
local compilerEnv = fixture.compilerEnv
local tempProject = fixture.tempProject
local remove = fixture.remove

local M = {}

function M.subprocessPreservesEmptyArguments()
    local dir = tempProject({["argv.lua"] = [[io.write(#arg, "|", arg[1], "|", arg[2])]],})
    local status, output = process.capture({"luajit", dir .. "/argv.lua", "", "tail"})
    remove(dir)
    testAssert.eq(status, 0, output)
    testAssert.eq(output, "2||tail", "an empty argv entry reaches the child process")
end

function M.nativeFacilitiesSharingAProviderBuildAsOneUnion()
    local originalCapture, originalCopy = process.capture, fs.copyFile
    local originalCompilerRoot = compilerEnv.compilerRoot
    local calls, copies = {}, {}
    -- The driver answers with the path it built, which is the last line it
    -- writes; anything before that is progress.
    process.capture = function(argv)
        calls[#calls + 1] = argv
        return 0, "/built/libnupp_native.dylib\n"
    end
    fs.copyFile = function(source, destination)
        copies[#copies + 1] = {source, destination}
        return true
    end
    compilerEnv.compilerRoot = function()
        return "."
    end
    local ok, outputs, problem = pcall(nativeStage.build, ".", "out", {["native.path"] = true, ["native.uuid"] = true,})
    process.capture, fs.copyFile = originalCapture, originalCopy
    compilerEnv.compilerRoot = originalCompilerRoot
    assert(ok, outputs)
    assert(outputs, problem)
    testAssert.eq(#calls, 1, "one provider union is built once")
    testAssert.eq(#copies, 2, "the shared library and path runtime are staged")
    local command = "\n" .. table.concat(calls[1], "\n") .. "\n"
    -- The path provider asks the operating system itself, so only UUID reaches
    -- the Rust union.
    assert(command:find("\nnative%-rust\nuuid\n"), "path and UUID select one Rust feature union")
    testAssert.eq(copies[1][1], "/built/libnupp_native.dylib", "the Rust provider union has one source artifact")
    assert(copies[1][2]:find("out/lib/nupp_native", 1, true), "the Rust provider union keeps its stable sidecar name")
end

function M.gpuNeverChangesTheHost()
    local originalCapture = process.capture
    local originalCompilerRoot = compilerEnv.compilerRoot
    local calls = {}
    process.capture = function(argv)
        calls[#calls + 1] = argv
        return 0, "/built/nupp-host\n"
    end
    compilerEnv.compilerRoot = function()
        return "."
    end
    local ok, problem = pcall(function()
        for _, enabled in ipairs({false, true}) do
            local effects = nativeStage.resolve({}, {gpu = enabled})
            local host, err = nativeStage.hostStub(".", "out", {stub = "nupp"}, effects)
            testAssert.eq(host, "/built/nupp-host", err)
        end
    end)
    process.capture = originalCapture
    compilerEnv.compilerRoot = originalCompilerRoot
    assert(ok, problem)
    testAssert.eq(#calls, 2, "each feature union selects its own host")
    testAssert.eq(calls[1][#calls[1]], "", "GPU is absent when disabled")
    testAssert.eq(calls[2][#calls[2]], "", "the GPU is a staged library, which no host links")
end

function M.nativeFacilityCanSelectItsProviderDriver()
    local originalCapture, originalCopy = process.capture, fs.copyFile
    local originalCompilerRoot = compilerEnv.compilerRoot
    local calls, copies = {}, {}
    process.capture = function(argv)
        calls[#calls + 1] = argv
        return 0, "/built/libwgpu_native.dylib\n"
    end
    fs.copyFile = function(source, destination)
        copies[#copies + 1] = {source, destination}
        return true
    end
    compilerEnv.compilerRoot = function()
        return "."
    end
    local ok, outputs, problem = pcall(nativeStage.build, ".", "out", {["native.gpu"] = true,})
    process.capture, fs.copyFile = originalCapture, originalCopy
    compilerEnv.compilerRoot = originalCompilerRoot
    assert(ok, outputs)
    assert(outputs, problem)
    testAssert.eq(#calls, 1, "the facility selects one provider build")
    local command = "\n" .. table.concat(calls[1], "\n") .. "\n"
    assert(command:find("\nwgpu\n"), "the feature's provider driver is passed to the toolchain")
    testAssert.eq(copies[1][1], "/built/libwgpu_native.dylib")
    assert(copies[1][2]:find("out/lib/wgpu_native", 1, true), "wgpu-native has an independent sidecar name")
end

-- wgpu-native is prebuilt for every platform, so a binary for another one
-- stages that platform's library, named the way its loader looks for it.
function M.aForeignTargetStagesItsOwnGpuLibrary()
    local originalCapture, originalCopy = process.capture, fs.copyFile
    local originalCompilerRoot = compilerEnv.compilerRoot
    local calls, copies = {}, {}
    process.capture = function(argv)
        calls[#calls + 1] = argv
        return 0, "/built/wgpu_native\n"
    end
    fs.copyFile = function(source, destination)
        copies[#copies + 1] = {source, destination}
        return true
    end
    compilerEnv.compilerRoot = function()
        return "."
    end
    local ok, problem = pcall(function()
        for platform, name in pairs({
            ["x86_64-pc-windows-msvc"] = "out/lib/wgpu_native.dll",
            ["aarch64-apple-darwin"] = "out/lib/wgpu_native",
        }) do
            calls, copies = {}, {}
            local outputs, err = nativeStage.build(".", "out", {["native.gpu"] = true}, platform)
            assert(outputs, err)
            local command = "\n" .. table.concat(calls[1], "\n") .. "\n"
            assert(command:find("\nwgpu\n" .. platform .. "\n", 1, true), command)
            assert(copies[1][2]:sub(-#name) == name, copies[1][2])
        end
        -- A standalone binary links the provider in, so nothing is staged for it.
        calls, copies = {}, {}
        local outputs, err = nativeStage.build(".", "out", {["native.gpu"] = true}, nil, nil, true)
        assert(outputs, err)
        testAssert.eq(#calls, 0, "a standalone build builds no GPU sidecar")
        for output in pairs(outputs) do
            assert(not output:find("wgpu_native", 1, true), output)
        end
    end)
    process.capture, fs.copyFile = originalCapture, originalCopy
    compilerEnv.compilerRoot = originalCompilerRoot
    assert(ok, problem)
end

-- The standalone link reads that platform's static library and keeps the
-- entry points the provider finds by name in the process.
function M.aStandaloneLinkKeepsTheGpuProvidersEntryPoints()
    local originalCapture = process.capture
    local originalCompilerRoot = compilerEnv.compilerRoot
    local calls = {}
    process.capture = function(argv)
        calls[#calls + 1] = argv
        return 0, "fetching\n/built/libwgpu_native.a\n"
    end
    compilerEnv.compilerRoot = function()
        return "."
    end
    local ok, problem = pcall(function()
        local effects = nativeStage.resolve({["native.gpu"] = true})
        local flags, err = nativeStage.linkedProviders(effects, "x86_64-unknown-linux-gnu")
        assert(flags, err)
        testAssert.eq(#calls, 1, "one static library is built")
        local command = "\n" .. table.concat(calls[1], "\n") .. "\n"
        assert(command:find("\nwgpu-static\nx86_64-unknown-linux-gnu\n", 1, true), command)
        testAssert.eq(flags[1], "/built/libwgpu_native.a")
        local kept = {}
        for index = 2, #flags do
            kept[assert(flags[index]:match("^%-%-undefined=(wgpu%w+)$"), flags[index])] = true
        end
        assert(kept.wgpuCreateInstance and kept.wgpuQueueSubmit, "the provider's entry points are kept")

        -- A macOS kit stubs the provider's frameworks apart from its own
        -- libraries; one built before it did is refused.
        calls = {}
        flags, err = nativeStage.linkedProviders(effects, "aarch64-apple-darwin")
        assert(flags == nil and err:find("cannot link native feature gpu", 1, true), err)
        local kit = tempProject({
            ["old/kit.json"] = [[{"schemaVersion": 1, "platform": "macos", "libraries": ["-lSystem"]}]],
            ["kit.json"] = [[{"schemaVersion": 1, "platform": "macos", "libraries": ["-lSystem"],
  "providers": {"wgpu": ["-framework", "Metal", "-lobjc"]}}]],
        })
        flags, err = nativeStage.linkedProviders(effects, "aarch64-apple-darwin", kit .. "/old")
        assert(flags == nil and err:find("no stubs for the system frameworks", 1, true), err)
        testAssert.eq(#calls, 0, "a refused platform fetches nothing")

        flags, err = nativeStage.linkedProviders(effects, "aarch64-apple-darwin", kit)
        remove(kit)
        assert(flags, err)
        testAssert.eq(#calls, 1, "one static library is built")
        command = "\n" .. table.concat(calls[1], "\n") .. "\n"
        assert(command:find("\nwgpu-static\naarch64-apple-darwin\n", 1, true), command)
        testAssert.eq(flags[1], "/built/libwgpu_native.a")
        kept = {}
        local index = 2
        while flags[index] == "-u" do
            kept[assert(flags[index + 1]:match("^_(wgpu%w+)$"), flags[index + 1])] = true
            index = index + 2
        end
        assert(kept.wgpuCreateInstance and kept.wgpuQueueSubmit, "the provider's entry points are kept")
        testAssert.eq(table.concat(flags, " ", index), "-framework Metal -lobjc", "the kit's frameworks follow")

        flags, err = nativeStage.linkedProviders(
            nativeStage.resolve({
                ["native.path"] = true
            }),
            "x86_64-unknown-linux-gnu"
        )
        assert(flags, err)
        testAssert.eq(#flags, 0, "a provider with a host implementation adds nothing")
    end)
    process.capture = originalCapture
    compilerEnv.compilerRoot = originalCompilerRoot
    assert(ok, problem)
end

-- What the standalone link keeps is what the binding declares: a function
-- added to the declarations without being kept would be missing from a
-- standalone binary, where only `ffi.C` can find it.
function M.theGpuProvidersKeptEntryPointsAreTheOnesItDeclares()
    local source = assert(fs.readFile("src/nupp/runtime/provider/wgpu.nupp"))
    local declared, kept = {}, {}
    for declarations in source:gmatch("ffi%.cdef%[%[(.-)%]%]") do
        for name in declarations:gmatch("[%w_]+%s*%*?%s*(wgpu%u%w*)%s*%(") do
            declared[#declared + 1] = name
        end
    end
    local effects = nativeStage.resolve({["native.gpu"] = true})
    for _, feature in ipairs(require("nupp.compiler.native").features(effects)) do
        for _, name in ipairs(feature.linkedSymbols or {}) do
            kept[#kept + 1] = name
        end
    end
    table.sort(declared)
    table.sort(kept)
    assert(#declared > 0, "the binding declares wgpu functions")
    testAssert.eq(table.concat(kept, " "), table.concat(declared, " "))
end

function M.aTargetKeepsTheRuntimeModuleItAlreadyBuilt()
    local originalCopy = fs.copyFile
    local originalCompilerRoot = compilerEnv.compilerRoot
    local copies = {}
    fs.copyFile = function(source, destination)
        copies[#copies + 1] = {source, destination}
        return true
    end
    compilerEnv.compilerRoot = function()
        return "/compiler"
    end
    local output = "/project/out/nupp/suspension.lua"
    local ok, outputs, problem = pcall(nativeStage.build, "/project", "out", {['runtime.suspension'] = true}, nil, {
        [output] = true
    })
    fs.copyFile = originalCopy
    compilerEnv.compilerRoot = originalCompilerRoot
    assert(ok, outputs)
    assert(outputs, problem)
    testAssert.eq(#copies, 0, "native staging preserves the target's generated runtime")
    assert(outputs[output], "the preserved runtime remains a staged output")

    copies = {}
    fs.copyFile = function(source, destination)
        copies[#copies + 1] = {source, destination}
        return true
    end
    compilerEnv.compilerRoot = function()
        return "/compiler"
    end
    ok, outputs, problem = pcall(nativeStage.build, "/project", "out", {['runtime.suspension'] = true})
    fs.copyFile = originalCopy
    compilerEnv.compilerRoot = originalCompilerRoot
    assert(ok, outputs)
    assert(outputs, problem)
    testAssert.eq(#copies, 1, "an application still receives the compiler runtime")
    testAssert.eq(copies[1][1], "/compiler/build/nupp/suspension.lua")
    testAssert.eq(copies[1][2], output)
end

return M
