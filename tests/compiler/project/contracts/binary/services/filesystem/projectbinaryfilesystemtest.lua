local fixture = require("helpers.projectfixture")
local testAssert = fixture.testAssert
local project = fixture.project
local deps = fixture.deps
local process = fixture.process
local nativeStage = fixture.nativeStage
local buildPlatform = fixture.buildPlatform
local json = fixture.json
local read = fixture.read
local exists = fixture.exists
local tempProject = fixture.tempProject
local remove = fixture.remove
local libraryName = fixture.libraryName
local executableName = fixture.executableName
local setEnvironment = fixture.setEnvironment

local M = {}

function M.standaloneBinaryReachesTheFilesystemThroughItsOwnFfi()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[return {include = {"src"}, build = {kind = "binary",
   stub = "nupp", standalone = true, outDir = "out", output = "out/app",
   entries = {"main"}}}]],
        [
            "src/main.nupp"
        ] = [[
assert(os.stat("nupp.lua") == "file")
local file = assert(io.open("nupp.lua", "rb"))
local contents = assert(file:read("*a"))
assert(contents:find("return", 1, true))
print("native-files-ok")
]],
    })
    testAssert.eq(project.build(dir), 0)
    local output = executableName(dir .. "/out/app")
    assert(exists(output), "the standalone filesystem executable is emitted")
    assert(not exists(dir .. "/out/lib/nupp_native"), "the standalone filesystem build needs no Rust sidecar")
    local code, text = process.capture({output})
    testAssert.eq(code, 0, text)
    testAssert.eq(
        text:match("[^\r\n]+"),
        "native-files-ok",
        "the executable calls the operating system through its own FFI"
    )
    remove(dir)
end

function M.standaloneBinaryPreservesDirectAndAliasedLuaPipes()
    local sources = {
        [[do
    local pipe = assert(io.popen("echo pipe-ok", "r"))
    assert(pipe:read("*l") == "pipe-ok")
end
]],
        [[local open = io.popen
do
    local pipe = assert(open("echo pipe-ok", "r"))
    assert(pipe:read("*l") == "pipe-ok")
end
]],
    }
    for index, source in ipairs(sources) do
        local dir = tempProject({
            [
                "nupp.lua"
            ] = [[return {include = {"src"}, build = {kind = "binary",
   stub = "nupp", standalone = true, outDir = "out", output = "out/app",
   entries = {"main"}}}]],
            ["src/main.nupp"] = source .. 'print("lua-pipe-ok")\n',
        })
        testAssert.eq(project.build(dir), 0, "standalone Lua pipe form " .. index)
        local output = executableName(dir .. "/out/app")
        assert(exists(output), "the standalone Lua pipe executable is emitted")
        for _, name in ipairs({
            "nupp_native",
            "nupp_native.dll",
            "nupp_native.dylib",
            "nupp_native.so",
            "libnupp_native.dylib",
            "libnupp_native.so"
        }) do
            assert(not exists(dir .. "/out/lib/" .. name), "the standalone Lua pipe retains no Rust sidecar")
        end
        local code, text = process.capture({output})
        testAssert.eq(code, 0, text)
        testAssert.eq(text:match("[^\r\n]+"), "lua-pipe-ok", "the Lua pipe reads and closes normally")
        remove(dir)
    end
end

return M
