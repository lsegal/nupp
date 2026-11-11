-- The Nupp host: host/program, the native program every stamped binary runs.
--
-- Two halves. The host's own modules are linked into small native programs
-- that probe one piece at a time -- the payload trailer's reader, the bounded
-- queues and endpoints under real threads, shared-byte builders and accounts --
-- the way a unit test would. Then the stub `scripts/toolchain host workers`
-- builds is run as somebody is handed it: unstamped and given a file, stamped
-- and damaged, and stamped with a payload that drives its worker lanes,
-- channels and shared bytes through `nupp.workers.native`.

local test = require("assert")

local HERE = require("helpers.paths").absoluteTests
local ROOT = HERE .. "/.."
local NUPP = ROOT .. "/bin/nupp"
local fixture = require("helpers.bundlefixture")
local packaging = require("nupp.tools.build.package")
local hash = require("nupp.compiler.hash")

local M = {}

local windows = jit.os == "Windows"
local EXE = windows and ".exe" or ""
local PLATFORM = windows and "windows" or jit.os == "OSX" and "darwin" or "linux"

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run(command)
    local pipe = assert(io.popen(command .. " 2>&1; printf '\n__status__:%s' $?"))
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__status__:(%d+)%s*$"))

    return status, (output:gsub("%s*__status__:%d+%s*$", ""):gsub("\r\n", "\n"))
end

local function temporary()
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p " .. quote(dir)) == 0)

    return dir
end

local function write(path, text)
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
end

local function read(path)
    local handle = assert(io.open(path, "rb"))
    local text = handle:read("*a")
    handle:close()

    return text
end

local function requireCodegen()
    local available, why = require("nupp.tools.build.aotllvm").selected()
    if available ~= true then
        test.suite.skip("this nupp has no code generator: " .. tostring(why))
    end
end

-- The host's modules ----------------------------------------------------------

--- Links `source` as a native program that may require the host's modules.
local function probe(source)
    requireCodegen()
    local dir = temporary()
    write(
        dir .. "/nupp.lua",
        ('return {include = {".", %q, %q}}\n'):format(
            ROOT .. "/host/program/common",
            ROOT .. "/host/program/" .. PLATFORM
        )
    )
    write(dir .. "/probe.nupp", source)
    local executable = dir .. "/probe" .. EXE
    local status, output = run(
        ("cd %s && NO_COLOR= %s aot --emit executable --output %s probe.nupp"):format(
            quote(dir),
            quote(NUPP),
            quote(executable)
        )
    )
    assert(status == 0, "the probe links:\n" .. output)

    return executable
end

local PAYLOAD_PROBE = [[
const sys = require("nupphost.sys")
const {nuppHostPayloadFind as find, FOUND, DAMAGED} = require("nupphost.payload")

cdef function malloc(size: uint64): voidptr?
cdef function printf(borrows format: cstring, ...): int32

local function main(argc: int32, argv: cstring*): int32
    local message = malloc(4096ULL)
    local found = malloc(24ULL)
    if message == nil or found == nil or argc < 2 then
        return 3
    end
    local path = @unsafe (argv[1])
    local bytes = sys.nuppHostSysReadFile(path, found as int64*, message as voidptr, 4096ULL)
    if bytes == nil then
        return 4
    end
    local size = @unsafe ((found as int64*)[0] as integer)
    local status = find(bytes as uint8*, size, found as int64*, message as voidptr, 4096ULL)
    if status == FOUND then
        @unsafe do
            local slots = found as int64*
            printf("found %lld %lld %lld\n", slots[0], slots[1], slots[2])
        end
    elseif status == DAMAGED then
        printf("damaged %s\n", message as cstring)
    else
        printf("none\n")
    end
    return 0
end
]]

local payloadProbe

local function findPayload(bytes)
    payloadProbe = payloadProbe or probe(PAYLOAD_PROBE)
    local file = temporary() .. "/image"
    write(file, bytes)
    local status, output = run(quote(payloadProbe) .. " " .. quote(file))
    assert(status == 0, output)

    return output:match("^(.-)\n?$")
end

local function le(value, width)
    local bytes = {}
    for index = 1, width do
        bytes[index] = string.char(value % 256)
        value = math.floor(value / 256)
    end

    return table.concat(bytes)
end

local MAX64 = ("\255"):rep(8)

--- `stub` with `payload` and its trailer after it, in the layout
--- docs/reference/distribution.md gives; `fields` replaces a trailer field.
local function stamped(stub, payload, fields)
    fields = fields or {}
    local trailer = "NUPPLOAD"
        .. (fields.version or le(1, 4))
        .. (fields.flags or le(0, 4))
        .. (fields.offset or le(#stub, 8))
        .. (fields.length or le(#payload, 8))
        .. (fields.digest or hash.trailerDigest(payload))
        .. le(48, 8)

    return stub .. payload .. trailer
end

--- A thin little-endian 64-bit Mach-O header with one LC_CODE_SIGNATURE, then a
--- stamped payload, `padding` and the signature blob at the end.
local function signed(payload, padding, signature)
    local header = "\207\250\237\254" .. ("\0"):rep(12) .. le(1, 4) .. le(16, 4) .. ("\0"):rep(8)
    local command = le(29, 4) .. le(16, 4)
    local image = stamped(header .. command .. ("\0"):rep(8), payload)
    image = image .. padding
    local at = #image
    image = image:sub(1, 40) .. le(at, 4) .. le(#signature, 4) .. image:sub(49)

    return image .. signature
end

function M.plainAndShortFilesHaveNoPayload()
    assert(findPayload("tiny") == "none")
    assert(findPayload(("x"):rep(68)) == "none")
end

function M.sourceAndBytecodePayloadsAreFound()
    local image = stamped("STUB", "return 42")
    assert(findPayload(image) == "found 4 9 0", findPayload(image))
    local bytecode = stamped("STUB", "\27LJ\2\0compiled", {flags = le(1, 4)})
    assert(findPayload(bytecode) == "found 4 13 1", findPayload(bytecode))
    -- Long enough for XXH64's four-lane path, so both of its paths agree with
    -- the compiler's own digest.
    local long = ("Nobody inspects the spammish repetition "):rep(5)
    assert(findPayload(stamped("STUB", long)) == "found 4 " .. #long .. " 0")
end

function M.emptyAndEmbeddedNulPayloadsAreNotSentinels()
    assert(findPayload(stamped("STUB", "")) == "found 4 0 0")
    assert(findPayload(stamped("STUB", "left\0middle\0right")) == "found 4 17 0")
end

function M.futureVersionsAndUnknownFlagsAreRefused()
    local version = findPayload(stamped("STUB", "return 1", {version = le(99, 4)}))
    assert(version:find("format version 99, and this host only knows version 1", 1, true), version)
    local flags = findPayload(stamped("STUB", "return 1", {flags = le(0x80000001, 4)}))
    assert(flags:find("unknown flags 0x80000001", 1, true), flags)
end

function M.everyInvalidPayloadBoundIsRefused()
    for _, bounds in ipairs({
        {MAX64, le(1, 8)},
        {le(4, 8), MAX64},
        {le(4, 8), le(9000, 8)},
        {le(4, 8), le(64, 8)},
    }) do
        local answer = findPayload(stamped("STUB", "return 1", {offset = bounds[1], length = bounds[2]}))
        assert(answer:find("probably truncated in transit", 1, true), answer)
    end
end

function M.aDigestMismatchIsRefused()
    local image = stamped("STUB", "return 1")
    image = image:sub(1, 4) .. "s" .. image:sub(6)
    local answer = findPayload(image)
    assert(answer:find("does not match the digest recorded beside it", 1, true), answer)
end

function M.aSignedMachOCarriesItsTrailerBeforePaddingAndSignature()
    local image = signed("return 'signed'", ("\0"):rep(17), "SIGNATURE")
    assert(findPayload(image):match("^found %d+ 15 0$"), findPayload(image))
end

function M.aSignedMachONeedsCleanPaddingAndAFinalSignature()
    assert(findPayload(signed("return 1", "\0\0\1\0", "SIGN")) == "none")
    assert(findPayload(signed("return 1", ("\0"):rep(3), "SIGN") .. "AFTER") == "none")
end

function M.malformedMachOLoadCommandsAreNotGuessed()
    local valid = signed("return 1", ("\0"):rep(3), "SIGN")
    for _, case in ipairs({{21, 0xffffffff}, {37, 7}, {37, 0xffffffff}, {37, 8}}) do
        local at = case[1]
        local malformed = valid:sub(1, at - 1) .. le(case[2], 4) .. valid:sub(at + 4)
        assert(findPayload(malformed) == "none", "load command field " .. at)
    end
end

-- Endpoints and queues, as the Rust host's channel tests had them, with real
-- threads where a wait is what is being tested.
local CHANNEL_PROBE = [[
const sys = require("nupphost.sys")
const channel = require("nupphost.channel")

cdef function calloc(count: uint64, size: uint64): voidptr?
cdef function free(borrows p: voidptr)

local function message(length: uint64): uint64
    local text = "abcdefghijklmnopqrstuvwxyz" as uint64
    return channel.nuppHostMessageNew(0, 0LL, 0, text, length, 0ULL, 0ULL, 0ULL, 0ULL, 0ULL, 0LL)
end

local function send(endpoint: uint64, length: uint64): int32
    local m = message(length)
    local status = channel.nuppHostEndpointTrySend(endpoint, m)
    if status ~= channel.SENT then
        channel.nuppHostMessageDestroy(m)
    end
    return status
end

--- What a receive reports, discarding any message.
local function receive(endpoint: uint64): int32
    local status = calloc(1ULL, 8ULL)
    if status == nil then
        return -1
    end
    local got = channel.nuppHostEndpointTryReceive(endpoint, status as int32*)
    local answer = @unsafe ((status as int32*)[0])
    free(status as voidptr)
    if got ~= 0ULL then
        channel.nuppHostMessageDestroy(got)
    end
    return answer
end

local function pair(messages: int64, bytes: uint64, borrows receiver: uint64*): uint64
    return channel.nuppHostEndpointPair(messages, bytes, receiver)
end

-- A thread's argument: [0] the endpoint, [1] the bytes to wait for, [2] what
-- the wait answered, [3] what to do: 1 wait, 2 transfer.
local function worker(argument: uint64): voidptr?
    local words = argument as uint64*
    @unsafe do
        if words[3] == 1ULL then
            words[2] = channel.nuppHostEndpointWaitReady(words[0], words[1], 1000LL) as uint64
        else
            words[2] = channel.nuppHostEndpointTransfer(words[0])
        end
    end
    return nil
end

local function start(endpoint: uint64, bytes: uint64, action: uint64): uint64
    local record = calloc(4ULL, 8ULL)
    if record == nil then
        return 0ULL
    end
    local words = record as uint64*
    @unsafe do
        words[0] = endpoint
        words[1] = bytes
        words[3] = action
    end
    return record as uint64
end

local function finish(record: uint64, thread: voidptr?): uint64
    if thread ~= nil then
        sys.nuppHostSysThreadJoin(thread as voidptr)
    end
    local answer = @unsafe ((record as uint64*)[2])
    free(record as voidptr)
    return answer
end

local function readinessObservesExactCapacityAndDrainingClose(borrows slot: uint64*): int32
    local sender = pair(2LL, 3ULL, slot)
    local receiver = @unsafe (slot[0])
    if channel.nuppHostEndpointReadiness(receiver, 0ULL) ~= channel.WAITING then
        return 1
    elseif channel.nuppHostEndpointReadiness(sender, 4ULL) ~= channel.OVERSIZED then
        return 2
    elseif send(sender, 2ULL) ~= channel.SENT then
        return 3
    elseif channel.nuppHostEndpointReadiness(sender, 1ULL) ~= channel.READY then
        return 4
    elseif channel.nuppHostEndpointReadiness(sender, 2ULL) ~= channel.WAITING then
        return 5
    end
    channel.nuppHostEndpointClose(sender)
    if channel.nuppHostEndpointReadiness(receiver, 0ULL) ~= channel.READY then
        return 6
    elseif receive(receiver) ~= channel.RECEIVED then
        return 7
    elseif channel.nuppHostEndpointReadiness(receiver, 0ULL) ~= channel.CLOSED then
        return 8
    elseif channel.nuppHostEndpointReadiness(sender, 0ULL) ~= channel.INVALID then
        return 9
    end
    channel.nuppHostEndpointRelease(sender)
    channel.nuppHostEndpointRelease(receiver)
    return 0
end

local function waitsWakeForCapacityMessagesAndPeerClose(borrows slot: uint64*): int32
    local sender = pair(1LL, 1ULL, slot)
    local receiver = @unsafe (slot[0])
    local record = start(receiver, 0ULL, 1ULL)
    local thread = sys.nuppHostSysThreadStart(worker, record)
    sys.nuppHostSysSleepMs(20LL)
    send(sender, 1ULL)
    if finish(record, thread) ~= (channel.READY as uint64) then
        return 11
    end
    record = start(sender, 1ULL, 1ULL)
    thread = sys.nuppHostSysThreadStart(worker, record)
    sys.nuppHostSysSleepMs(20LL)
    receive(receiver)
    if finish(record, thread) ~= (channel.READY as uint64) then
        return 12
    end
    send(sender, 1ULL)
    record = start(sender, 1ULL, 1ULL)
    thread = sys.nuppHostSysThreadStart(worker, record)
    sys.nuppHostSysSleepMs(20LL)
    channel.nuppHostEndpointClose(receiver)
    if finish(record, thread) ~= (channel.CLOSED as uint64) then
        return 13
    end
    channel.nuppHostEndpointRelease(sender)
    channel.nuppHostEndpointRelease(receiver)
    return 0
end

local function movingADirectionWakesAndInvalidatesOldWaits(borrows slot: uint64*): int32
    local sender = pair(1LL, 1ULL, slot)
    local receiver = @unsafe (slot[0])
    send(sender, 1ULL)
    local record = start(sender, 1ULL, 1ULL)
    local thread = sys.nuppHostSysThreadStart(worker, record)
    sys.nuppHostSysSleepMs(20LL)
    local moved = channel.nuppHostEndpointTransfer(sender)
    if finish(record, thread) ~= (channel.INVALID as uint64) then
        return 21
    elseif receive(receiver) ~= channel.RECEIVED then
        return 22
    elseif channel.nuppHostEndpointWaitReady(moved, 1ULL, 0LL) ~= channel.READY then
        return 23
    end
    channel.nuppHostEndpointRelease(sender)
    channel.nuppHostEndpointRelease(moved)
    channel.nuppHostEndpointRelease(receiver)
    return 0
end

local function movesInvalidateOldGenerationsWithoutClosingTheSuccessor(borrows slot: uint64*): int32
    local sender = pair(2LL, 8ULL, slot)
    local receiver = @unsafe (slot[0])
    local moved = channel.nuppHostEndpointTransfer(sender)
    if channel.nuppHostEndpointIsLive(sender) or channel.nuppHostEndpointTransfer(sender) ~= 0ULL then
        return 31
    elseif send(sender, 1ULL) ~= channel.INVALID then
        return 32
    end
    channel.nuppHostEndpointRelease(sender)
    if send(moved, 1ULL) ~= channel.SENT or receive(receiver) ~= channel.RECEIVED then
        return 33
    elseif receive(receiver) ~= channel.EMPTY then
        return 34
    end
    channel.nuppHostEndpointRelease(moved)
    if receive(receiver) ~= channel.CLOSED then
        return 35
    end
    channel.nuppHostEndpointRelease(receiver)
    return 0
end

local function directionsLimitsAndUnsentPayloadsAreEnforced(borrows slot: uint64*): int32
    local sender = pair(1LL, 2ULL, slot)
    local receiver = @unsafe (slot[0])
    if send(receiver, 1ULL) ~= channel.INVALID or receive(sender) ~= channel.INVALID then
        return 41
    elseif send(sender, 3ULL) ~= channel.OVERSIZED then
        return 42
    elseif send(sender, 2ULL) ~= channel.SENT or send(sender, 1ULL) ~= channel.FULL then
        return 43
    end
    channel.nuppHostEndpointClose(receiver)
    if send(sender, 1ULL) ~= channel.CLOSED then
        return 44
    end
    channel.nuppHostEndpointRelease(sender)
    channel.nuppHostEndpointRelease(receiver)
    return 0
end

local function aTransferRaceMintsExactlyOneSuccessor(borrows slot: uint64*): int32
    for _ = 1, 100 do
        local sender = pair(1LL, 1ULL, slot)
        local receiver = @unsafe (slot[0])
        local left = start(sender, 0ULL, 2ULL)
        local right = start(sender, 0ULL, 2ULL)
        local leftThread = sys.nuppHostSysThreadStart(worker, left)
        local rightThread = sys.nuppHostSysThreadStart(worker, right)
        local first = finish(left, leftThread)
        local second = finish(right, rightThread)
        if (first ~= 0ULL) == (second ~= 0ULL) then
            return 51
        end
        local successor = first
        if successor == 0ULL then
            successor = second
        end
        channel.nuppHostEndpointRelease(sender)
        if send(successor, 1ULL) ~= channel.SENT or receive(receiver) ~= channel.RECEIVED then
            return 52
        end
        channel.nuppHostEndpointRelease(successor)
        channel.nuppHostEndpointRelease(receiver)
    end
    return 0
end

local function aFailedTransferDropsTheDirectionAndUnreadStorage(borrows slot: uint64*): int32
    local sender = pair(1LL, 8ULL, slot)
    local receiver = @unsafe (slot[0])
    send(sender, 1ULL)
    local inTransit = channel.nuppHostEndpointTransfer(receiver)
    channel.nuppHostEndpointRelease(inTransit)
    if send(sender, 1ULL) ~= channel.CLOSED then
        return 61
    elseif receive(receiver) ~= channel.INVALID then
        return 62
    end
    channel.nuppHostEndpointRelease(sender)
    channel.nuppHostEndpointRelease(receiver)
    return 0
end

local function main(): int32
    if not channel.nuppHostChannelInitialize() then
        return 100
    end
    local slot = calloc(1ULL, 8ULL) as uint64*
    local failed = readinessObservesExactCapacityAndDrainingClose(slot)
    if failed == 0 then
        failed = waitsWakeForCapacityMessagesAndPeerClose(slot)
    end
    if failed == 0 then
        failed = movingADirectionWakesAndInvalidatesOldWaits(slot)
    end
    if failed == 0 then
        failed = movesInvalidateOldGenerationsWithoutClosingTheSuccessor(slot)
    end
    if failed == 0 then
        failed = directionsLimitsAndUnsentPayloadsAreEnforced(slot)
    end
    if failed == 0 then
        failed = aTransferRaceMintsExactlyOneSuccessor(slot)
    end
    if failed == 0 then
        failed = aFailedTransferDropsTheDirectionAndUnreadStorage(slot)
    end
    return failed
end
]]

function M.endpointsKeepTheirGenerationsLimitsAndWakeups()
    local status, output = run(quote(probe(CHANNEL_PROBE)))
    assert(status == 0, "the channel probe failed check " .. tostring(status) .. "\n" .. output)
end

local BYTES_PROBE = [[
const region = require("nupphost.region")

local function main(): int32
    local builder = region.nuppHostBuilderNew()
    local text = "abcdef" as uint64
    if not region.nuppHostBuilderAppend(builder, text, 3ULL) then
        return 1
    end
    local reserved = region.nuppHostBuilderReserve(builder, 4ULL)
    if reserved == 0ULL or not region.nuppHostBuilderOpen(builder) then
        return 2
    end
    -- An open reservation refuses everything but its commit.
    if region.nuppHostBuilderAppend(builder, text, 1ULL) or region.nuppHostBuilderReserve(builder, 1ULL) ~= 0ULL then
        return 3
    elseif region.nuppHostBuilderFreeze(builder) ~= 0ULL then
        return 4
    elseif region.nuppHostBuilderCommit(builder, 5ULL) then
        return 5
    end
    @unsafe do
        (reserved as uint8*)[0] = 120
    end
    if not region.nuppHostBuilderCommit(builder, 1ULL) or region.nuppHostBuilderCommit(builder, 0ULL) then
        return 6
    end
    local block = region.nuppHostBuilderFreeze(builder)
    if block == 0ULL or region.nuppHostRegionLength(block) ~= 4ULL then
        return 7
    end
    @unsafe do
        local bytes = region.nuppHostRegionData(block) as uint8*
        if bytes[0] ~= 97 or bytes[2] ~= 99 or bytes[3] ~= 120 then
            return 8
        end
    end
    if region.nuppHostBuilderFreeze(builder) ~= 0ULL then
        return 9
    end
    region.nuppHostBuilderFree(builder)

    -- An account counts each block once however many handles reach it, and
    -- asks for a collector step once a mebibyte of debt is owed.
    local account = region.nuppHostAccountNew()
    if region.nuppHostAccountCharge(account, block) ~= 0ULL or region.nuppHostAccountCharge(account, block) ~= 0ULL then
        return 10
    elseif region.nuppHostAccounted(account) ~= 4ULL then
        return 11
    end
    region.nuppHostAccountDischarge(account, block)
    if region.nuppHostAccounted(account) ~= 4ULL then
        return 12
    end
    region.nuppHostAccountDischarge(account, block)
    if region.nuppHostAccounted(account) ~= 0ULL then
        return 13
    end
    local big = region.nuppHostRegionNew(text, 0ULL)
    local wide = region.nuppHostBuilderNew()
    region.nuppHostBuilderReserve(wide, 2097152ULL)
    region.nuppHostBuilderCommit(wide, 2097152ULL)
    local large = region.nuppHostBuilderFreeze(wide)
    region.nuppHostBuilderFree(wide)
    if region.nuppHostAccountCharge(account, large) ~= 2048ULL then
        return 14
    end
    region.nuppHostAccountFree(account)
    region.nuppHostRegionRelease(big)
    region.nuppHostRegionRelease(large)
    region.nuppHostRegionRelease(block)
    return 0
end
]]

function M.buildersReservationsAndAccountsKeepTheirRules()
    local status, output = run(quote(probe(BYTES_PROBE)))
    assert(status == 0, "the shared-byte probe failed check " .. tostring(status) .. "\n" .. output)
end

-- The stub ---------------------------------------------------------------------

local function stub()
    requireCodegen()

    return fixture.nativeHost()
end

local function stampedHost(payload, flags)
    local dir = temporary()
    local output = dir .. "/app" .. EXE
    local written, problem = packaging.stampFile(output, read(stub()), payload, nil, flags or 0)
    assert(written, problem)

    return output, dir
end

local function writeHost(bytes)
    local dir = temporary()
    local output = dir .. "/app" .. EXE
    write(output, bytes)
    if not windows then
        assert(os.execute("chmod +x " .. quote(output)) == 0)
    end
    -- macOS runs only a signed image; signing puts the signature after the
    -- trailer, which is where a signed host looks for it.
    if jit.os == "OSX" then
        assert(os.execute("codesign --force --sign - " .. quote(output) .. " 2>/dev/null") == 0)
    end

    return output
end

function M.anUnstampedHostAsksForAFile()
    local status, output = run(quote(stub()))
    assert(status == 2, output)
    assert(output:find("nupp-host: no payload; usage: ", 1, true), output)
    assert(output:find("<file.lua> [args...]", 1, true), output)
    local missing, why = run(quote(stub()) .. " " .. quote(temporary() .. "/missing.lua"))
    assert(missing == 1 and why:find("nupp-host: cannot read ", 1, true), why)
end

function M.anUnstampedHostKeepsTheFileNameAndItsArguments()
    local file = temporary() .. "/cli fixture.lua"
    write(file, [[
assert(debug.getinfo(1, "S").source == "@" .. arg[1])
assert(arg[2] == "one" and arg[3] == "two" and #arg == 3)
assert(__nuppHost.hostAbi == 1 and __nuppHost.hostFeatures["native-checksum"])
assert(__nuppHost.hostFeatures.workers == nil, "workers are a stamped host's")
assert(require("jit.vmdef") and require("jit.bc") and require("jit.zone"))
assert(__NUPP_EXECUTABLE ~= nil)
print("ran")
]])
    local status, output = run(quote(stub()) .. " " .. quote(file) .. " " .. quote(file) .. " one two")
    assert(status == 0 and output == "ran\n", output)
end

function M.statesKeepMoreTracesThanLuaJitsDefaultLimit()
    -- LuaJIT flushes every trace once 1000 are live; a host state raises the
    -- limit before its first trace, so 1500 live loops compile without one.
    local file = temporary() .. "/traces.lua"
    write(file, [[
local flushes = 0
local function watch(what) if what == "flush" then flushes = flushes + 1 end end
jit.attach(watch, "trace")
jit.opt.start("hotloop=1")
local keep = {}
for k = 1, 1500 do
    local source = "return function(n) local s = 0 for i = 1, n do s = s + i * %d end return s end"
    keep[k] = loadstring(source:format(k))()
    keep[k](50)
end
jit.attach(watch)
print(flushes)
]])
    local status, output = run(quote(stub()) .. " " .. quote(file))
    assert(status == 0 and output == "0\n", output)
end

function M.aStampedHostRunsSourceAndBytecodeWithItsArguments()
    local program = [[
assert(debug.getinfo(1, "S").source == "@" .. __NUPP_EXECUTABLE)
print(#arg, arg[1], __nuppHost.hostFeatures.workers)
]]
    local source = stampedHost(program)
    local status, output = run(quote(source) .. " first")
    assert(status == 0 and output == "1\tfirst\ttrue\n", output)
    local bytecode, flags = packaging.payloadBytes(program, nil)
    local compiled = stampedHost(bytecode, flags)
    status, output = run(quote(compiled) .. " first")
    assert(status == 0 and output == "1\tfirst\ttrue\n", output)
end

function M.aDamagedStampIsRefusedRatherThanRun()
    local image = read(stub())
    local cases = {
        {{version = le(99, 4)}, "format version 99"},
        {{flags = le(0x80000001, 4)}, "unknown flags 0x80000001"},
        {{offset = MAX64, length = le(1, 8)}, "probably truncated in transit"},
        {{digest = ("\0"):rep(8)}, "does not match the digest"},
    }
    for _, case in ipairs(cases) do
        local host = writeHost(stamped(image, "print('ran')", case[1]))
        local status, output = run(quote(host))
        assert(status == 1, output)
        assert(output:find("^nupp: ") and output:find(case[2], 1, true), output)
        assert(not output:find("ran", 1, true), output)
    end
end

function M.aFailingPayloadSaysWhyAndFails()
    local host = stampedHost("error('the payload stopped here', 0)")
    local status, output = run(quote(host))
    assert(status == 1 and output == "the payload stopped here\n", output)
end

-- A payload that is both sides of a worker lane: run in a worker state it
-- answers its inbox and stops, and run as the program it spawns one.
local LANE = [[
local native = require("nupp.workers.native")
if __nuppWorkerIn ~= nil then
    local inbox, outbox = native.current()
    local header, body = native.channelPop(inbox, 5000)
    if body == "fail" then
        error("the lane was asked to fail", 0)
    end
    assert(native.channelPush(outbox, "re:" .. header, body:upper()))
    return
end
local inbox, outbox = native.channelCreate(), native.channelCreate()
local lane, problem = native.workerSpawn(inbox, outbox)
assert(lane, problem)
assert(native.workerParallelism() >= 1)
assert(native.workerTaskCreate(lane, 7, nil))
assert(not native.workerTaskCreate(lane, 7, nil), "a task id is used once")
assert(native.workerTaskStatus(lane, 7) == 1)
assert(native.workerTaskCancel(lane, 7) == 1)
assert(native.workerTaskStatus(lane, 7) == 4)
native.workerTaskRelease(lane, 7)
assert(native.workerTaskStatus(lane, 7) == 0)
assert(native.channelPush(inbox, "hello", arg[1]))
local header, body = native.channelPop(outbox, 5000)
local status, why = native.workerJoin(lane)
native.channelDestroy(inbox)
native.channelDestroy(outbox)
print(header, body, status, why)
]]

function M.aStampedHostRunsWorkerLanes()
    local host = stampedHost(LANE)
    local status, output = run(quote(host) .. " shout")
    assert(status == 0 and output == "re:hello\tSHOUT\t0\tnil\n", output)
    status, output = run(quote(host) .. " fail")
    assert(status == 0 and output == "nil\tnil\t1\tthe lane was asked to fail\n", output)
end

local SURFACE = [[
local native = require("nupp.workers.native")
local shared = require("nupp.mem.sharedbytes.native")

local sender, receiver = native.endpointCreate(2, 8)
assert(native.endpointDirection(sender) == 1 and native.endpointDirection(receiver) == 0)
assert(native.endpointReady(sender, 4) == 0 and native.endpointReady(receiver, 0) == 1)
assert(native.endpointSend(sender, "abcd") == 0)
assert(native.endpointSend(sender, "toolarge!") == 3)
assert(native.endpointSend(receiver, "x") == 4)
local moved = native.endpointMove(sender)
assert(native.endpointDirection(sender) == -1, "a moved handle names nothing")
assert(native.endpointSend(moved, "efgh") == 0)
assert(native.endpointSend(moved, "i") == 1, "the byte bound is full")
local status, text = native.endpointReceive(receiver)
assert(status == 0 and text == "abcd", tostring(status))
assert(native.endpointWait(moved, 4, 0) == 0)
native.endpointClose(moved)
status, text = native.endpointReceive(receiver)
assert(status == 0 and text == "efgh")
status = native.endpointReceive(receiver)
assert(status == 2, "a drained channel whose sender closed is closed")
assert(not pcall(native.endpointCreate, 0, 1))

local region, length = shared.fromString("shared bytes")
assert(length == 12 and shared.length(region) == 12)
assert(shared.text(region, 1, 6) == "shared" and shared.text(region, 13, 12) == "")
assert(shared.text(region, 0, 1) == nil and shared.text(region, 1, 13) == nil)
assert(shared.accounted() == 12)
local builder = shared.builderNew()
assert(shared.builderAppend(builder, "ab"))
local pointer = shared.builderReserve(builder, 3)
assert(pointer ~= nil)
local ok, open = shared.builderAppend(builder, "c")
assert(not ok and open == "open")
assert(shared.builderCommit(builder, 0))
local frozen, frozenLength = shared.builderFreeze(builder)
assert(frozenLength == 2 and shared.text(frozen, 1, 2) == "ab")
assert(shared.builderFreeze(builder) == nil)

local message = native.messageCreate()
assert(native.messageFill(message, "payload", {region, 1, 6}))
assert(native.messageSize(message) == 7 + 12)
local out, back = native.endpointCreate(1, 64)
assert(native.messageOffer(out, message) == 0)
status, text, attachments = native.endpointReceive(back)
assert(status == 0 and text == "payload")
assert(shared.text(attachments[1], attachments[2], attachments[3]) == "shared")
local file = os.tmpname()
local handle = io.open(file, "wb")
handle:write("from a file")
handle:close()
local read, problem = shared.readFile(file)
os.remove(file)
assert(read and shared.text(read, 1, 4) == "from", problem)
local missing, why = shared.readFile(file)
assert(missing == nil and why:find("cannot read", 1, true), why)
print("surface")
]]

function M.aStampedHostServesTheEndpointAndSharedByteSurface()
    local host = stampedHost(SURFACE)
    local status, output = run(quote(host))
    assert(status == 0 and output == "surface\n", output)
end

return M
