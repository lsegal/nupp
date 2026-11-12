-- The FFI process provider against real children.
--
-- Each case the former Rust process crate tested has its counterpart here: exit
-- codes against terminating signals, output read through to its end, input
-- backpressure, kill and reap, and an exit that stops being news once polled.
-- The readiness cases prove a wait parks rather than spins, and that activity in
-- another native family -- a socket accepting a connection -- still wakes it.
local test = require("assert")
local nativeStage = require("nupp.tools.build.native")
local process = require("nupp.compiler.process")

local M = {}

local provider, root, unavailable, priorPreload, priorLoaded, nativeLibrary

local WINDOWS = package.config:sub(1, 1) == "\\"
local SHELL = os.getenv("NUPP_TEST_SH") or "/bin/sh"
-- Git Bash is the Windows test shell; elsewhere `sh` may lack `/dev/tcp`.
local BASH = WINDOWS and SHELL or "bash"

local function shell(script)
    return {SHELL, "-c", script}
end

-- A direct child that lives for half a minute and reads nothing, so killing it
-- leaves no grandchild holding its pipes.
local function longRunning()
    if WINDOWS then
        return {"ping", "-n", "31", "127.0.0.1"}
    end

    return {"sleep", "30"}
end

-- Processor seconds this process has used. `os.clock` measures that on POSIX,
-- but the Microsoft C runtime answers wall time since start.
local processorSeconds = os.clock
if WINDOWS then
    local ffi = require("ffi")
    pcall(
        ffi.cdef,
        [[
    int32_t GetProcessTimes(void *, uint64_t *, uint64_t *, uint64_t *, uint64_t *);
    void *GetCurrentProcess(void);
    ]]
    )
    local times = ffi.new("uint64_t[4]")
    processorSeconds = function()
        assert(ffi.C.GetProcessTimes(ffi.C.GetCurrentProcess(), times, times + 1, times + 2, times + 3) ~= 0)
        return tonumber(times[2] + times[3]) / 1e7
    end
end

local function temporaryRoot()
    local base = (os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp"):gsub("\\", "/"):gsub("/$", "")
    local unique = tostring({}):match("(%x+)$") or "0"

    return base .. "/nupp-process-provider-" .. tostring(os.time()) .. "-" .. unique
end

-- The provider opens the library `nupp.runtime.native` chooses, which reads
-- `NUPP_NATIVE_LIBRARY`; a suite cannot set that for itself, so it preloads the
-- module with the lookup answered.
local function preloadNative(libraryPath)
    local found = assert(package.searchpath("nupp.runtime.native", package.path))
    local text = assert(io.open(found, "rb")):read("*a"):gsub('os%.getenv%("NUPP_NATIVE_LIBRARY"%)', function()
        return ("%q"):format(libraryPath)
    end)
    package.loaded["nupp.runtime.native"] = nil
    package.preload["nupp.runtime.native"] = assert(loadstring(text, "@nupp.runtime.native"))
end

function M.beforeAll()
    root = temporaryRoot()
    os.execute("mkdir -p '" .. root .. "'")
    local staged, problem = nativeStage.build(root, "out", {["native.process"] = true})
    if not staged then
        unavailable = tostring(problem)
        return
    end
    -- Nupp spawns, reaps and waits on children itself, so processes stage no
    -- provider, and the library named here does not exist: a provider symbol
    -- reached anywhere below fails instead of quietly loading one.
    test.eq(next(staged), nil, "processes staged a native provider")
    local libraryPath = root .. "/out/lib/nupp_native"
    nativeLibrary = libraryPath
    priorPreload = package.preload["nupp.runtime.native"]
    priorLoaded = package.loaded["nupp.runtime.native"]
    preloadNative(libraryPath)
    package.loaded["nupp.runtime.provider.nativeprocess"] = nil
    provider = require("nupp.runtime.provider.nativeprocess")
end

function M.afterAll()
    package.loaded["nupp.runtime.provider.nativeprocess"] = nil
    package.preload["nupp.runtime.native"] = priorPreload
    package.loaded["nupp.runtime.native"] = priorLoaded
    if root then
        os.execute("rm -rf '" .. root .. "'")
    end
end

local function ready()
    if unavailable then
        test.suite.skip("the native provider did not build: " .. unavailable)
    end

    return provider
end

local function spawn(args, options)
    local given = {args = args, stdin = "pipe", stdout = "pipe", stderr = "pipe"}
    for key, value in pairs(options or {}) do
        given[key] = value
    end
    local owner, input, output, err, pid, problem, code = provider:spawn(given)
    assert(owner ~= nil, tostring(problem))
    assert(type(pid) == "number" and pid > 0)

    return {owner = owner, input = input, output = output, err = err}
end

local function interest(child, read, write)
    return {child = child, read = read or {}, write = write or {}}
end

local function waitExit(child, seconds)
    local deadline = os.monotonic() + (seconds or 10) * 1000
    while true do
        local exit = provider:poll(child.owner)
        if exit then
            return exit
        end
        assert(os.monotonic() < deadline, "the child did not exit")
        provider:waitready(interest(child.owner), 100)
    end
end

local function drain(child, stream)
    local parts = {}
    local deadline = os.monotonic() + 10000
    while true do
        local bytes = provider:read(stream, 4096)
        if bytes == nil then
            return table.concat(parts)
        elseif bytes == "" then
            assert(os.monotonic() < deadline, "the stream never ended")
            provider:waitready(interest(nil, {stream}), 1000)
        else
            parts[#parts + 1] = bytes
        end
    end
end

local function finish(child)
    for _, stream in ipairs({child.input, child.output, child.err}) do
        if stream then
            assert(provider:closestream(stream))
        end
    end
    assert(provider:reap(child.owner))
end

function M.outputIsReadThroughToItsEnd()
    ready()
    local child = spawn(shell("printf process-output"))
    test.eq(drain(child, child.output), "process-output")
    test.eq(drain(child, child.err), "")
    local exit = waitExit(child)
    test.eq(exit.exitcode, 0)
    test.eq(exit.killed, false)
    test.eq(exit.signal, nil)
    finish(child)
end

function M.inputReachesAChildThatReadsIt()
    ready()
    local child = spawn(shell("cat"))
    local wrote, gone = provider:write(child.input, "one")
    test.eq(wrote, 3)
    test.eq(gone, false)
    -- Closing with the write possibly still in flight delivers it, then EOF.
    assert(provider:closestream(child.input))
    assert(provider:closestream(child.input), "a second close is harmless")
    test.eq(drain(child, child.output), "one")
    test.eq(waitExit(child).exitcode, 0)
    child.input = nil
    finish(child)
end

function M.mergedStderrSharesTheStdoutPipe()
    ready()
    local child = spawn(shell("printf out; printf err >&2"), {stderr = "stdout"})
    test.eq(child.err, nil)
    test.eq(drain(child, child.output), "outerr")
    test.eq(waitExit(child).exitcode, 0)
    finish(child)
end

function M.environmentAndDirectoryReachTheChild()
    ready()
    local child = spawn(shell("printf '%s|' \"$NUPP_PROVIDER_PROBE\"; pwd"), {
        env = {NUPP_PROVIDER_PROBE = "probe value"},
        cwd = WINDOWS and os.getenv("SystemRoot") or "/",
    })
    local text = drain(child, child.output)
    assert(text:find("^probe value|"), text)
    if not WINDOWS then
        test.eq(text, "probe value|/\n")
    end
    waitExit(child)
    finish(child)
end

function M.exitCodesAreReported()
    ready()
    local child = spawn(shell("exit 7"), {stdin = "null", stdout = "null", stderr = "null"})
    test.eq(child.input, nil)
    test.eq(child.output, nil)
    local exit = waitExit(child)
    test.eq(exit.exitcode, 7)
    test.eq(exit.killed, false)
    finish(child)
end

-- The checker declares every literal cdef block of a file it checks to the
-- compiler's own FFI, the other platform's block included, and can do that
-- before the compiler first loads this provider (#117). A fresh interpreter
-- that has declared them the same way, the other platform's first, must still
-- start a child. This suite's own interpreter already holds the provider's
-- types, so the case needs one of its own.
local DECLARED_FIRST = [==[
local ffi = require("ffi")
local source, library, shellPath, declared = ...
if declared then
    ffi.cdef(declared)
else
    local blocks = {}
    for block in assert(io.open(source, "rb")):read("*a"):gmatch("ffi%s*%.%s*cdef%s*%[%[(.-)%]%]") do
        table.insert(blocks, ffi.os == "Windows" and 1 or #blocks + 1, block)
    end
    assert(#blocks >= 2, "expected one cdef block per platform")
    for _, block in ipairs(blocks) do
        pcall(ffi.cdef, block)
    end
end
local text = assert(io.open(assert(package.searchpath("nupp.runtime.native", package.path)), "rb")):read("*a")
text = text:gsub('os%.getenv%("NUPP_NATIVE_LIBRARY"%)', function()
    return ("%q"):format(library)
end)
package.preload["nupp.runtime.native"] = assert(loadstring(text, "@nupp.runtime.native"))
local provider = require("nupp.runtime.provider.nativeprocess")
local owner, _, _, _, _, problem = provider:spawn({
    args = {shellPath, "-c", "exit 7"}, stdin = "null", stdout = "null", stderr = "null",
})
assert(owner ~= nil, tostring(problem))
local exit
repeat
    exit = provider:poll(owner)
    if not exit then
        provider:waitready({child = owner, read = {}, write = {}}, 100)
    end
until exit
assert(provider:reap(owner))
io.write("exit ", tostring(exit.exitcode))
]==]

local function declaredFirst(declared)
    local script = process.tmpname() .. ".lua"
    local handle = assert(io.open(script, "wb"))
    handle:write(DECLARED_FIRST)
    handle:close()
    local source = assert(package.searchpath("nupp.runtime.provider.nativeprocess", package.path))
    local status, output = process.capture({"luajit", script, source, nativeLibrary, SHELL, declared}, {
        env = {LUA_PATH = package.path, LUA_CPATH = package.cpath},
    })
    os.remove(script)

    return status, output
end

function M.theOtherPlatformsDeclarationsDoNotShadowTheProvidersTypes()
    ready()
    local status, output = declaredFirst()
    test.eq(output, "exit 7")
    test.eq(status, 0)
end

-- Another copy or version of the provider can hold one of its names in another
-- shape. The provider cannot redefine it, so it has to refuse by name rather
-- than index a field the type does not have.
function M.aDifferentlyShapedEarlierDeclarationIsRefusedByName()
    ready()
    local name = WINDOWS and "NuppProcessWindowsChild" or "NuppProcessPosixChild"
    local status, output = declaredFirst("typedef struct { void *elsewhere; } " .. name .. ";")
    test.ne(status, 0)
    assert(output:find(name .. " was already declared without the field", 1, true), output)
end

function M.aSignalExitStaysDistinctFromAnEqualExitCode()
    ready()
    if WINDOWS then
        test.suite.skip("Windows has no terminating signals")
    end
    local signalled = spawn(shell("kill -TERM $$"))
    local exit = waitExit(signalled)
    test.eq(exit.exitcode, 143)
    test.eq(exit.killed, true)
    test.eq(exit.signal, 15)
    finish(signalled)

    local numeric = spawn(shell("exit 143"))
    exit = waitExit(numeric)
    test.eq(exit.exitcode, 143)
    test.eq(exit.killed, false)
    test.eq(exit.signal, nil)
    finish(numeric)
end

function M.aChildThatExitsOnItsOwnAfterAPoliteKillWasNotKilled()
    ready()
    if WINDOWS then
        test.suite.skip("Windows has no polite termination signal")
    end
    local child = spawn(shell("trap 'exit 0' TERM; echo ready; read line"))
    local seen = ""
    while not seen:find("\n") do
        local bytes = provider:read(child.output, 64)
        assert(bytes ~= nil, "the child ended before it was ready")
        seen = seen .. bytes
        if bytes == "" then
            provider:waitready(interest(nil, {child.output}), 1000)
        end
    end
    provider:kill(child.owner, false)
    local exit = waitExit(child)
    test.eq(exit.exitcode, 0)
    test.eq(exit.killed, false)
    finish(child)
end

function M.killThenReap()
    ready()
    local child = spawn(longRunning())
    local reaped, problem = provider:reap(child.owner)
    test.eq(reaped, false)
    assert(tostring(problem):find("has not ended", 1, true), tostring(problem))
    provider:kill(child.owner, true)
    local exit = waitExit(child)
    test.eq(exit.killed, true)
    provider:kill(child.owner, true)
    finish(child)
    assert(provider:reap(child.owner), "a second reap is harmless")
end

-- Only one write is in flight at a time, which is observable only while a write
-- cannot finish. This child never reads, so once the loop has filled its pipe
-- every later write is refused and the stream stays unwritable.
function M.inputBackpressureRefusesWritesWhileThePipeIsFull()
    ready()
    local child = spawn(longRunning(), {stdout = "null", stderr = "null"})
    local chunk = string.rep("f", 65536)
    local deadline = os.monotonic() + 30000
    while provider:waitready(interest(nil, {}, {child.input}), 2000) ~= 0 do
        local wrote, gone = provider:write(child.input, chunk)
        test.eq(gone, false)
        assert(wrote == 0 or wrote > 0 and wrote <= #chunk)
        assert(os.monotonic() < deadline, "the input pipe never filled")
    end
    local wrote, gone = provider:write(child.input, "two")
    test.eq(wrote, 0)
    test.eq(gone, false)
    test.eq(provider:waitready(interest(nil, {}, {child.input}), 200), 0)
    provider:kill(child.owner, true)
    assert(waitExit(child).killed)
    finish(child)
end

function M.writingToAChildThatClosedItsInputReportsAClosedPipe()
    ready()
    local child = spawn(shell("exec 0<&-; exit 0"), {stdout = "null", stderr = "null"})
    waitExit(child)
    local deadline = os.monotonic() + 10000
    while true do
        local _, gone = provider:write(child.input, "late")
        if gone then
            break
        end
        assert(os.monotonic() < deadline, "the closed pipe was never reported")
        provider:waitready(interest(nil, {}, {child.input}), 100)
    end
    finish(child)
end

function M.aCollectedExitLeavesAWaitToItsStreams()
    ready()
    -- The child exits at once; the sleep it started keeps stdout open.
    local child = spawn(shell("sleep 2 & exit 0"), {stdin = "null", stderr = "null"})
    local deadline = os.monotonic() + 10000
    while provider:waitready(interest(child.owner), 1000) == 0 do
        assert(os.monotonic() < deadline, "the child did not exit")
    end
    test.eq(provider:waitready(interest(child.owner, {child.output}), 0), 1, "an exit nobody has collected is news")
    assert(provider:poll(child.owner))
    test.eq(provider:waitready(interest(child.owner, {child.output}), 50), 0, "a collected exit is not news again")
    assert(provider:closestream(child.output))
    assert(provider:reap(child.owner))
end

function M.aMissingProgramAnswersAReasonAndAnErrorNumber()
    ready()
    local owner, input, output, err, pid, problem, code = provider:spawn({args = {"/__nupp_missing_process__/missing"}})
    test.eq(owner, nil)
    test.eq(input, nil)
    test.eq(output, nil)
    test.eq(err, nil)
    test.eq(pid, 0)
    assert(type(problem) == "string" and problem:find("could not start process", 1, true), tostring(problem))
    assert(type(code) == "number" and code ~= 0, tostring(code))
end

function M.descriptorsThatCouldNeverStartAChildRaise()
    ready()

    local function rejects(options, expected)
        local ok, problem = pcall(provider.spawn, provider, options)
        assert(not ok and tostring(problem):find(expected, 1, true), tostring(problem))
    end

    rejects({args = {}}, "needs a program")
    for _, name in ipairs({"A=B", "=A", ""}) do
        rejects({args = {"true"}, env = {[name] = "C"}}, "environment variable name")
    end
    rejects({args = {"true"}, stdin = "stdout"}, "no stdin mode")
    rejects({args = {"true"}, stdout = "stdout"}, "no stdout mode")
    rejects({args = {"true"}, stderr = "sideways"}, "no stderr mode")
    rejects({args = {"tr\0ue"}}, "embedded NUL")
end

function M.concurrentChildrenAreKilledAndReapedWithoutStrandedStreams()
    ready()
    local children = {}
    for index = 1, 16 do
        children[index] = spawn(longRunning())
    end
    for _, child in ipairs(children) do
        provider:kill(child.owner, true)
        for _, stream in ipairs({child.input, child.output, child.err}) do
            assert(provider:closestream(stream))
        end
    end
    for _, child in ipairs(children) do
        assert(waitExit(child).killed)
        assert(provider:reap(child.owner))
    end

    local short = {}
    for index = 1, 32 do
        short[index] = spawn(shell("exit 0"))
    end
    for _, child in ipairs(short) do
        test.eq(waitExit(child).exitcode, 0)
        finish(child)
    end
end

-- A wait with nothing to report sleeps in the kernel for its whole budget,
-- using next to no processor time, rather than polling.
function M.aQuietWaitParksInsteadOfSpinning()
    ready()
    local child = spawn(longRunning(), {stdout = "null", stderr = "null"})
    local started, cpu = os.monotonic(), processorSeconds()
    test.eq(provider:waitready(interest(child.owner, {}, {}), 400), 0)
    local elapsed, used = os.monotonic() - started, processorSeconds() - cpu
    assert(elapsed >= 300, "the wait returned early after " .. elapsed .. "ms")
    assert(used < 0.2, "the wait spent " .. used .. "s of processor time")
    provider:kill(child.owner, true)
    waitExit(child)
    finish(child)
end

return M
