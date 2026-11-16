local fixture = require("helpers.projectfixture")
local testAssert = fixture.testAssert
local project = fixture.project
local process = fixture.process
local buildPlatform = fixture.buildPlatform
local write = fixture.write
local tempProject = fixture.tempProject
local remove = fixture.remove

local M = {}

function M.sourceFixpointNamesTheStageZeroToItsWorkers()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[return {include = {"src"}, build = {
   entries = {"main"}, outDir = "out"},
   selfHost = {bootstrap = "luajit find-stage0.lua"}}]],
        ["src/main.nupp"] = "return 1\n",
        [
            "stage0.lua"
        ] = [[
local input = assert(io.open(arg[0], "rb"))
local source = input:read("*a")
input:close()
if arg[0]:match("stage0%.lua$") then
   assert(os.getenv("NUPP_STAGE0") == arg[0], "workers need this stage-zero entry")
end
local output
for index = 1, #arg do
   if arg[index] == "--out-dir" or arg[index] == "--output" then output = arg[index + 1] end
end
assert(output)
os.execute('mkdir "' .. output .. '"')
local file = assert(io.open(output .. "/main.lua", "wb"))
file:write(source)
file:close()
]],
    })
    write(dir .. "/find-stage0.lua", ("print(%q)\n"):format(dir .. "/stage0.lua"))
    local ok, status = pcall(project.fixpoint, dir, {result = {}})
    remove(dir)
    assert(ok, status)
    testAssert.eq(status, 0, "each stage can launch workers through the selected compiler")
end

-- A compiler that copies itself as a stage's whole output, lowers a native
-- program to text naming its entry (and, when a `differ` file exists, naming
-- the compiler that lowered it), and logs every call with the provider it ran on.
local NATIVE_STAGE0 = [[
local input = assert(io.open(arg[0], "rb"))
local source = input:read("*a")
input:close()
local output
for index = 1, #arg do
   if arg[index] == "--output" then output = arg[index + 1] end
end
assert(output)
local log = assert(io.open("calls.log", "ab"))
log:write(table.concat({arg[1], arg[#arg], tostring(os.getenv("NUPP_NATIVE_LIBRARY")), output}, "|"), "\n")
log:close()
if arg[1] == "aot" then
   local text = "lowered " .. arg[#arg]
   local differ = io.open("differ", "rb")
   if differ then
      differ:close()
      text = text .. " by " .. arg[0]
   end
   local file = assert(io.open(output, "wb"))
   file:write(text)
   file:close()
   return
end
os.execute('mkdir "' .. output .. '"')
local file = assert(io.open(output .. "/main.lua", "wb"))
file:write(source)
file:close()
]]

-- The project's toolchain driver, writing two native programs' sources.
local NATIVE_DRIVER = [[
[ "$1" = native-sources ] || exit 2
mkdir -p "$2/provider" "$2/host"
: > "$2/provider/main.nupp"
: > "$2/provider/exports"
: > "$2/host/main.nupp"
printf 'program provider %s\n' "$2/provider/main.nupp"
printf 'exports provider %s\n' "$2/provider/exports"
printf 'program host %s\n' "$2/host/main.nupp"
]]

local function nativeProject()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[return {include = {"src"}, build = {
   entries = {"main"}, outDir = "out"},
   selfHost = {bootstrap = "luajit find-stage0.lua"}}]],
        ["src/main.nupp"] = "return 1\n",
        ["stage0.lua"] = NATIVE_STAGE0,
        ["scripts/toolchain"] = NATIVE_DRIVER,
    })
    write(dir .. "/find-stage0.lua", ("print(%q)\n"):format(dir .. "/stage0.lua"))
    return dir
end

local function calls(dir)
    local file = assert(io.open(dir .. "/calls.log", "rb"))
    local text = file:read("*a")
    file:close()
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        local command, last, provider, output = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
        lines[#lines + 1] = {command = command, last = last, provider = provider, output = output}
    end
    return lines
end

local function withCodeGenerator(available, body)
    local aotllvm = require("nupp.tools.build.aotllvm")
    local old = aotllvm.selected
    aotllvm.selected = function()
        return available or nil
    end
    local ok, a, b = pcall(body)
    aotllvm.selected = old
    assert(ok, a)
    return a, b
end

function M.fixpointHasStagesTwoAndThreeLowerTheNativePrograms()
    local dir = nativeProject()
    local result = {}
    local status = withCodeGenerator(false, function()
        return project.fixpoint(dir, {result = result})
    end)
    local lowered = {}
    for _, call in ipairs(calls(dir)) do
        if call.command == "aot" then
            lowered[#lowered + 1] = call.output:match("(_stage%d)/") .. " " .. call.last:match("([^/]+)/main%.nupp$")
        end
    end
    local leftover = io.open(dir .. "/_native/_stage2/provider.ll", "rb")
    if leftover then
        leftover:close()
    end
    remove(dir)
    testAssert.eq(status, 0, "identical native IR is a fixpoint")
    testAssert.eq(
        table.concat(lowered, ","),
        "_stage2 provider,_stage2 host,_stage3 provider,_stage3 host",
        "stage zero's lowering is not compared; stages two and three each lower every program"
    )
    testAssert.eq(table.concat(result.native, ","), "provider,host", "the report names the programs")
    testAssert.eq(result.nativeRelinked, false, "without a code generator nothing is relinked")
    testAssert.eq(leftover, nil, "a passing run removes the native stages")
end

function M.fixpointRefusesStagesThatLowerANativeProgramDifferently()
    local dir = nativeProject()
    write(dir .. "/differ", "")
    local result = {}
    local status = withCodeGenerator(false, function()
        return project.fixpoint(dir, {result = result, diagnostics = {}})
    end)
    local kept = io.open(dir .. "/_native/_stage3/host.ll", "rb")
    if kept then
        kept:close()
    end
    remove(dir)
    testAssert.eq(status, 1, "stage-dependent IR breaks the fixpoint")
    testAssert.eq(result.reason, "the two stages lower a native program differently")
    testAssert.truthy(kept, "the differing IR is kept for inspection")
end

function M.fixpointRunsEachStageOnTheProviderTheStageBeforeLinked()
    local dir = nativeProject()
    local result = {}
    local status = withCodeGenerator(true, function()
        return project.fixpoint(dir, {result = result})
    end)
    local log = calls(dir)
    remove(dir)
    testAssert.eq(status, 0)
    testAssert.eq(result.nativeRelinked, true)
    local linked, stage3
    for _, call in ipairs(log) do
        if call.command == "aot" and call.output:match("_stage2/") and not call.output:match("%.ll$") then
            linked = call.output
        end
        if call.command == "build" and call.output == "_stage3" then
            stage3 = call.provider
        end
    end
    testAssert.truthy(linked, "stage two links a provider")
    testAssert.eq(stage3, linked, "stage three is built on the provider stage two linked")
end

function M.binaryFixpointReadsThePlatformNamedHostOutput()
    local dir = tempProject({
        [
            "nupp.lua"
        ] = [[return {include = {"src"}, build = {targets = {dist = {
   kind = "binary", stub = "nupp", output = "out/app", entries = {"main"},
}}}, selfHost = {binary = "dist"}}]],
        ["src/main.nupp"] = "return 1\n",
    })
    local output = dir .. "/out/app.exe"
    local oldBuild, oldRun, oldHostKey = project.build, process.run, buildPlatform.hostKey
    project.build = function(_, opts)
        write(output, "same stamped bytes")
        opts.produced.artifact = output
        return 0
    end
    process.run = function(argv)
        testAssert.eq(argv[1], output .. ".stage1", "fixpoint executes the platform-named stage")
        write(output, "same stamped bytes")
        return 0
    end
    buildPlatform.hostKey = function()
        return "x86_64-pc-windows-msvc"
    end
    local ok, status = pcall(project.binaryFixpoint, dir, {result = {}})
    project.build, process.run, buildPlatform.hostKey = oldBuild, oldRun, oldHostKey
    remove(dir)
    assert(ok, status)
    testAssert.eq(status, 0, "the Windows executable suffix is shared with the build")
end

return M
