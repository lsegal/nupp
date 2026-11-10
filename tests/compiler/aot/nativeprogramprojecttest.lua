-- `kind = "program"`: a project target that `nupp build` links as a native
-- program, the way `nupp aot --emit executable` does.
--
-- Driven through the real binary, and the program it links is run, because the
-- executable, its place under the target's `outDir` and whether a rebuild
-- relinks it are the interface.

local test = require("assert")

local HERE = require("helpers.paths").absoluteTests
local NUPP = HERE .. "/../bin/nupp"

local M = {}

local EXE = jit.os == "Windows" and ".exe" or ""

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run(command)
    local pipe = assert(io.popen(command .. " 2>&1; printf '\n__status__:%s' $?"))
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__status__:(%d+)%s*$"))

    return status, (output:gsub("%s*__status__:%d+%s*$", ""))
end

local function write(path, text)
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
end

local function program(exit)
    return (
        [[
cdef function puts(borrows s: cstring): int32

local function main(): int32
    puts("native %d")
    return %d
end
]]
    ):format(exit, exit)
end

--- A project whose `host` target is the program in `src/host.nupp`.
local function project(target, source)
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p " .. quote(dir .. "/src")) == 0)
    write(dir .. "/nupp.lua", ('return {include = {"src"}, build = {targets = {host = %s}}}\n'):format(target))
    write(dir .. "/src/host.nupp", source or program(3))

    return dir
end

local function build(dir, extra)
    return run(("cd %s && NO_COLOR= %s build --target host%s"):format(quote(dir), quote(NUPP), extra or ""))
end

--- Whether `path` was written after `reference`, which a link would do.
local function newer(path, reference)
    return os.execute(("test %s -nt %s"):format(quote(path), quote(reference))) == 0
end

local function requireCodegen()
    local available, why = require("nupp.tools.build.aotllvm").selected()
    if available ~= true then
        test.suite.skip("this nupp has no code generator: " .. tostring(why))
    end
end

function M.aProgramTargetBuildsAProgramThatRuns()
    requireCodegen()
    local dir = project('{kind = "program", entries = {"host"}, outDir = "out"}')
    local status, output = build(dir)
    test.eq(status, 0, output)
    local ran
    status, ran = run(quote(dir .. "/out/host" .. EXE))
    test.eq(status, 3, ran)
    test.eq(ran, "native 3")
end

function M.outputNamesTheExecutable()
    requireCodegen()
    local dir = project('{kind = "program", entries = {"host"}, output = "bin/tool' .. EXE .. '"}')
    local status, output = build(dir, " --json")
    test.eq(status, 0, output)
    assert(output:find("bin/tool" .. EXE, 1, true), output)
    local ran
    status, ran = run(quote(dir .. "/bin/tool" .. EXE))
    test.eq(status, 3, ran)
end

function M.anUnchangedProgramIsNotRelinked()
    requireCodegen()
    local dir = project('{kind = "program", entries = {"host"}, outDir = "out"}')
    local executable = dir .. "/out/host" .. EXE
    local reference = dir .. "/reference"
    local status, output = build(dir)
    test.eq(status, 0, output)
    -- Dated into the past, so a link this build makes is one `-nt` can see.
    write(reference, "")
    assert(os.execute(("touch -t 200001010000 %s"):format(quote(executable))) == 0)
    assert(os.execute(("touch -t 200001020000 %s"):format(quote(reference))) == 0)

    status, output = build(dir)
    test.eq(status, 0, output)
    assert(not newer(executable, reference), "an unchanged program was relinked")

    write(dir .. "/src/host.nupp", program(5))
    status, output = build(dir)
    test.eq(status, 0, output)
    assert(newer(executable, reference), "a changed program was not relinked")
    local ran
    status, ran = run(quote(executable))
    test.eq(status, 5, ran)
end

function M.aReplacedExecutableIsLinkedAgain()
    requireCodegen()
    local dir = project('{kind = "program", entries = {"host"}, outDir = "out"}')
    local executable = dir .. "/out/host" .. EXE
    local status, output = build(dir)
    test.eq(status, 0, output)
    write(executable, "not a program")
    status, output = build(dir)
    test.eq(status, 0, output)
    local ran
    status, ran = run(quote(executable))
    test.eq(status, 3, ran)
end

-- What lowering refuses is reported where it was written, before anything is
-- linked, so this needs no code generator.
function M.whatLoweringRefusesIsReportedAtItsSource()
    local dir = project(
        '{kind = "program", entries = {"host"}}',
        'print("not native")\n\nlocal function main(): int32\n    return 0\nend\n'
    )
    local status, output = build(dir)
    assert(status ~= 0, output)
    assert(output:find("host.nupp:1:1: native: a native program's top level holds only", 1, true), output)
end

function M.aProgramTargetNamesOneEntry()
    local dir = project('{kind = "program", entries = {"host", "other"}}')
    local status, output = build(dir)
    assert(status ~= 0, output)
    assert(output:find("build.targets.host.entries names the one module a program target links", 1, true), output)
end

function M.anEntryNoIncludeRootHasIsRefused()
    local dir = project('{kind = "program", entries = {"missing"}}')
    local status, output = build(dir)
    assert(status ~= 0, output)
    assert(output:find("program target host names entry missing", 1, true), output)
end

return M
