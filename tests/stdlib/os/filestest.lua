require("nupp.runtime.standardos")
-- The `os` filesystem functions against a real filesystem, through the real provider.
--
-- The launcher's provider is reused when available, and otherwise one is built for
-- the suite. It is reached the way a generated program reaches it, so what is proved
-- here is the binding and ABI rather than a mock of either. Building one is the
-- prerequisite; without it the fallback skips rather than failing for another
-- reason.
require("nupp.runtime.standardcoroutine")
local test = require("assert")
local native = require("nupp.compiler.native")
local stdlib = require("nupp.compiler.stdlib")
local nativeStage = require("nupp.tools.build.native")

local M = {}

-- Whether a reason is a io.Error: a kind to branch on and a message that is
-- also what it prints as.
local function isIoError(reason, kind)
    return type(reason) == "table"
        and type(reason.kind) == "string"
        and type(reason.message) == "string"
        and #reason.message > 0
        and tostring(reason) == reason.message
        and (kind == nil or reason.kind == kind)
end

local root, provider, buffers, previous
local unavailable

local function temporaryRoot()
    local base = os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp"
    base = base:gsub("\\", "/")
    -- Suite shards start in the same second with the same random seed. Include
    -- a per-process address so one shard cannot remove another shard's root.
    local unique = tostring({}):match("(%x+)$") or "0"

    return (
        base:gsub("/$", "")
    ) .. "/nupp-files-test-" .. tostring(os.time()) .. "-" .. unique .. "-" .. tostring(math.random(1, 1e9))
end

function M.beforeAll()
    math.randomseed(os.time())
    root = temporaryRoot()
    os.execute("mkdir -p '" .. root .. "'")
    local libraryPath = os.getenv("NUPP_NATIVE_LIBRARY")
    if not libraryPath then
        local staged, problem = nativeStage.build(root, "out", {["native.files"] = true})
        if not staged then
            unavailable = tostring(problem)
            return
        end
        libraryPath = root .. "/out/lib/nupp_native"
    end
    -- A generated program finds the library beside itself. This chunk is loaded
    -- from a string, so it has no beside; name the staged library outright, which
    -- is the same substitution the NUPP_NATIVE_LIBRARY override performs.
    local library = ("%q"):format(libraryPath)
    local source = stdlib.bootstrap({
        ["native.files"] = true,
        ["stdlib.io"] = true,
    }):gsub(
        'os%.getenv%("NUPP_NATIVE_LIBRARY"%)',
        function()
            return library
        end
    )
    previous = rawget(_G, "nupp")
    _G.nupp = nil
    assert(loadstring(source))()
    provider = os
    buffers = require("bytes")
end

function M.afterAll()
    if previous ~= nil or rawget(_G, "nupp") ~= nil then
        _G.nupp = previous
    end
    if root then
        os.execute("chmod -R u+w '" .. root .. "' 2>/dev/null")
        os.execute("rm -rf '" .. root .. "'")
    end
end

local function ready()
    if unavailable then
        test.suite.skip("the files provider did not build: " .. unavailable)
    end
    return provider
end

local function inRoot(name)
    return root .. "/" .. name
end

local function write(path, text)
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
end

function M.directoriesAreCreatedWithTheirParents()
    local files = ready()
    assert(files.mkdir(inRoot("a/b/c")))
    test.eq(files.stat(inRoot("a/b/c")), "directory")
    test.eq(files.stat(inRoot("a")), "directory")
    assert(files.mkdir(inRoot("a/b/c")), "creating an existing directory succeeds")
end

local function readFile(path)
    local file, reason = io.open(path, "rb")
    if file == nil then
        return nil, reason
    end
    local bytes, readReason = file:read("*a")
    local closed, closeReason = file:close()
    if bytes == nil then
        return nil, readReason
    end
    if not closed then
        return nil, closeReason
    end

    return bytes
end

local function writeFile(path, bytes, mode)
    local file, reason = io.open(path, mode or "wb")
    if file == nil then
        return false, reason
    end
    local written, writeReason = file:write(bytes)
    local closed, closeReason = file:close()
    if written == nil then
        return false, writeReason
    end
    if not closed then
        return false, closeReason
    end

    return true
end

local function appendFile(path, bytes)
    return writeFile(path, bytes, "ab")
end

function M.statRejectsNonBooleanLinkFlags()
    local files = ready()
    for _, flag in ipairs({"true", 1, {}}) do
        test.raises(
            function()
                files.stat(inRoot("unused"), flag)
            end,
            "boolean expected"
        )
    end
end

function M.statDescribesAFileAndFailsOnAMissingOne()
    local files = ready()
    assert(files.mkdir(inRoot("info")))
    write(inRoot("info/five.txt"), "hello")
    local kind, size, modified, readonly, err = files.stat(inRoot("info/five.txt"))
    test.eq(kind, "file", tostring(err))
    test.eq(size, 5)
    test.eq(readonly, false)
    test.eq(err, nil)
    assert(modified > 1500000000000, "a modification time is a Unix timestamp in milliseconds")
    local now = os.walltime()
    assert(math.abs(now - modified) < 1000, "a fresh write's time is the clock's, in the clock's unit")

    local count = select("#", files.stat(inRoot("info/absent")))
    test.eq(count, 5, "a failure keeps the error in the last position")
    local missingKind, missingSize, missingModified, missingReadonly, reason = files.stat(inRoot("info/absent"))
    test.eq(missingKind, nil)
    test.eq(missingSize, nil)
    test.eq(missingModified, nil)
    test.eq(missingReadonly, nil)
    assert(isIoError(reason, "notfound"), "a missing path is notFound, whatever the platform said")
    assert(("cannot read: " .. reason):find(reason.message, 1, true), "and joins text as its message")
end

function M.existsAnswersPresenceAndKeepsFailuresApart()
    local files = ready()
    assert(files.mkdir(inRoot("presence")))
    write(inRoot("presence/here.txt"), "x")
    test.eq(files.exists(inRoot("presence/here.txt")), true)
    test.eq(files.exists(inRoot("presence")), true)
    local missing, reason = files.exists(inRoot("presence/absent"))
    test.eq(missing, false)
    test.eq(reason, nil, "absence is an answer, not a failure")
    test.eq(files.exists(inRoot("presence/absent/deeper")), false)
    assert(files.symlink(inRoot("presence/absent"), inRoot("presence/dangling")))
    test.eq(files.exists(inRoot("presence/dangling")), false, "a dangling link does not resolve")
    test.eq(files.stat(inRoot("presence/dangling"), true), "symlink", "but the link itself is there")
end

function M.symbolicLinksAreCreatedReadAndDistinguished()
    local files = ready()
    assert(files.mkdir(inRoot("links")))
    write(inRoot("links/target.txt"), "bytes")
    assert(files.symlink(inRoot("links/target.txt"), inRoot("links/alias")))

    test.eq(files.stat(inRoot("links/alias"), true), "symlink")
    test.eq(files.stat(inRoot("links/target.txt"), true), "file")
    local missing, _, _, _, reason = files.stat(inRoot("links/absent"), true)
    test.eq(missing, nil)
    assert(isIoError(reason, "notfound"), "a missing link is a reason, not a kind")
    test.eq(files.stat(inRoot("links/alias")), "file", "stat follows the link by default")
    test.eq(files.stat(inRoot("links/alias"), false), "file", "false follows the link")
    test.eq(files.stat(inRoot("links/alias"), nil), "file", "nil follows the link")
    local target = assert(files.readlink(inRoot("links/alias")))
    test.eq(target:tostring(), inRoot("links/target.txt"), "a link's target is a path value")
end

function M.listingDescribesEachChildWithoutFollowingLinks()
    local files = ready()
    assert(files.mkdir(inRoot("listing/child")))
    write(inRoot("listing/file.txt"), "x")
    assert(files.symlink(inRoot("listing/file.txt"), inRoot("listing/alias")))

    local kinds, count = {}, 0
    for name, kind in files.list(inRoot("listing")) do
        kinds[name] = kind
        count = count + 1
    end
    test.eq(count, 3)
    test.eq(kinds["child"], "directory")
    test.eq(kinds["file.txt"], "file")
    test.eq(kinds["alias"], "symlink")

    local ok, reason = pcall(files.list, inRoot("listing/absent"))
    test.eq(ok, false)
    assert(
        type(reason) == "string" and reason:find(inRoot("listing/absent"), 1, true),
        "a directory that cannot be read raises with its name: " .. tostring(reason)
    )
end

function M.listingStreamsDirectoriesLargerThanOneBatch()
    local files = ready()
    assert(files.mkdir(inRoot("many")))
    for index = 1, 600 do
        write(inRoot("many/" .. index .. ".txt"), "")
    end
    local seen, count = {}, 0
    for name, kind in files.list(inRoot("many")) do
        test.eq(kind, "file")
        assert(not seen[name], "an entry arrives once: " .. name)
        seen[name] = true
        count = count + 1
    end
    test.eq(count, 600)

    -- A loop that stops early leaves its directory to the collector, so many
    -- abandoned listings must not exhaust anything.
    for _ = 1, 2000 do
        for _ in files.list(inRoot("many")) do
            break
        end
    end
    collectgarbage()
    collectgarbage()
    local after = 0
    for _ in files.list(inRoot("many")) do
        after = after + 1
    end
    test.eq(after, 600)
end

function M.globbingMatchesRecursivelyAndSortsPaths()
    local files = ready()
    assert(files.mkdir(inRoot("glob/nested/deep")))
    write(inRoot("glob/root.nupp"), "root")
    write(inRoot("glob/nested/child.nupp"), "child")
    write(inRoot("glob/nested/deep/leaf.nupp"), "leaf")
    write(inRoot("glob/nested/deep/ignored.lua"), "ignored")

    local matches = assert(files.glob(inRoot("glob/**/*.nupp")))
    local separator = package.config:sub(1, 1)

    local function nativePath(path)
        local normalized = path:gsub("[/\\]", separator)
        return normalized
    end

    for index, path in ipairs(matches) do
        assert(type(path) == "table", "a match is a path value")
        matches[index] = nativePath(path:tostring())
    end
    test.eq(
        table.concat(matches, "|"),
        table.concat(
            {
                nativePath(inRoot("glob/nested/child.nupp")),
                nativePath(inRoot("glob/nested/deep/leaf.nupp")),
                nativePath(inRoot("glob/root.nupp")),
            },
            "|"
        )
    )
    test.eq(#assert(files.glob(inRoot("glob/*.txt"))), 0, "no matches answers an empty list")

    local invalid, reason = files.glob(inRoot("glob/["))
    test.eq(invalid, nil)
    assert(isIoError(reason), "an invalid pattern answers a reason")
end

function M.renamingAndRemovingMoveAndDeletePaths()
    local files = ready()
    assert(files.mkdir(inRoot("moves/tree/deep")))
    write(inRoot("moves/from.txt"), "content")
    assert(os.rename(io.Path.of(inRoot("moves/from.txt")), inRoot("moves/to.txt")))
    test.eq(files.stat(inRoot("moves/to.txt")), "file")
    assert(not files.exists(inRoot("moves/from.txt")))

    assert(os.remove(io.Path.of(inRoot("moves/to.txt"))))
    assert(not files.exists(inRoot("moves/to.txt")))

    local refused, reason = os.remove(inRoot("moves/tree"))
    assert(not refused and type(reason) == "string", "removing a populated directory needs the recursive flag")
    assert(os.remove(io.Path.of(inRoot("moves/tree")), true))
    assert(not files.exists(inRoot("moves/tree")))
end

function M.temporariesAreCreatedNotProposed()
    local files = ready()
    assert(files.mkdir(inRoot("temporary")))
    local file = assert(files.mktemp("unit-", ".tmp", inRoot("temporary")))
    local name = file:tostring()
    test.eq(files.stat(name), "file", "the temporary file exists when its name is answered")
    assert(
        name:find("/unit-", 1, true) and name:sub(-4) == ".tmp",
        "the generated name carries the prefix and suffix: " .. name
    )

    local other = assert(files.mktemp(nil, nil, inRoot("temporary")))
    test.ne(other:tostring(), name, "two temporaries do not collide")

    local directory = assert(files.mktempdir(nil, nil, inRoot("temporary")))
    test.eq(files.stat(directory:tostring()), "directory")

    local absent, reason = files.mktemp(nil, nil, inRoot("temporary/absent"))
    test.eq(absent, nil)
    assert(isIoError(reason), "an unusable directory answers a reason")

    local escaped, escapeReason = files.mktemp("../outside-", nil, inRoot("temporary"))
    test.eq(escaped, nil)
    assert(isIoError(escapeReason), "a name fragment cannot escape its selected directory")

    other:close()
    directory:close()
    file:close()
end

function M.aTemporaryIsRemovedOnCloseAndKeptOnPersist()
    local files = ready()
    assert(files.mkdir(inRoot("settling")))
    local doomed = assert(files.mktemp(nil, nil, inRoot("settling")))
    local name = doomed:tostring()
    test.eq(doomed:path():tostring(), name, "a temporary answers its path as a path value too")
    test.eq(files.stat(name), "file")
    test.eq(select("#", doomed:close()), 0, "a temporary's close answers nothing")
    test.eq(files.exists(name), false, "closing removes what was created")
    assert(doomed:isreleased())
    doomed:close()

    local kept = assert(files.mktemp(nil, nil, inRoot("settling")))
    assert(writeFile(kept:tostring(), "final"))
    assert(kept:persist(inRoot("settling/report.txt")))
    assert(kept:isreleased(), "persisting discharges the obligation")
    kept:close()
    test.eq(assert(readFile(inRoot("settling/report.txt"))), "final", "the persisted file survives the close")
end

function M.wholeFilesAreReadWrittenAndCopied()
    local files = ready()

    local function succeeds(label, ...)
        local answer, reason = ...
        assert(answer, label .. ": " .. tostring(reason))
        return answer
    end

    succeeds("create whole directory", files.mkdir(inRoot("whole")))
    succeeds("initial write", writeFile(inRoot("whole/a.txt"), "hello"))
    test.eq(assert(readFile(inRoot("whole/a.txt"))), "hello")
    succeeds("append", appendFile(inRoot("whole/a.txt"), " world"))
    test.eq(assert(readFile(inRoot("whole/a.txt"))), "hello world")

    succeeds("append creates a missing file", appendFile(inRoot("whole/new.txt"), "created"))
    test.eq(assert(readFile(inRoot("whole/new.txt"))), "created")

    succeeds("atomic replacement", files.writeatomic(inRoot("whole/a.txt"), "replaced"))
    test.eq(assert(readFile(inRoot("whole/a.txt"))), "replaced")
    for name in files.list(inRoot("whole")) do
        assert(not name:find("^%.nupp%-write%-"), "an atomic write leaves no temporary behind: " .. name)
    end

    succeeds("copy", files.copy(inRoot("whole/a.txt"), inRoot("whole/b.txt")))
    test.eq(assert(readFile(inRoot("whole/b.txt"))), "replaced")

    succeeds("empty write", writeFile(inRoot("whole/empty.txt"), ""))
    test.eq(assert(readFile(inRoot("whole/empty.txt"))), "")
    -- `nul`, even with an extension, names the Windows null device rather than
    -- an ordinary file. The contents are what this case is about, not the name.
    succeeds("NUL write", writeFile(inRoot("whole/embedded-nul.bin"), "a\0b"))
    test.eq(assert(readFile(inRoot("whole/embedded-nul.bin"))), "a\0b", "a NUL byte is content, not a terminator")

    local missing, reason = readFile(inRoot("whole/absent"))
    test.eq(missing, nil)
    assert(type(reason) == "string" and #reason > 0)
end

function M.transfersSettleThroughTheLaneAndReleaseTheirSlots()
    local files = ready()
    local backend = require("nupp.runtime.provider.nativefiles")
    assert(files.mkdir(inRoot("lane")))
    test.eq(backend.pendingTransfers(), 0, "the lane starts idle")

    local payload = ("lane"):rep(50000)
    for index = 1, 24 do
        assert(backend.write(inRoot("lane/" .. index .. ".bin"), payload))
    end
    for index = 1, 24 do
        test.eq(#assert(backend.read(inRoot("lane/" .. index .. ".bin"))), #payload)
    end
    assert(backend.append(inRoot("lane/1.bin"), ":tail"))
    test.eq(assert(backend.read(inRoot("lane/1.bin"))), payload .. ":tail")
    test.eq(backend.pendingTransfers(), 0, "every settled transfer gave its slot back")

    local missing, reason = backend.read(inRoot("lane/absent"))
    test.eq(missing, nil)
    assert(type(reason) == "string" and #reason > 0)
    test.eq(backend.pendingTransfers(), 0, "a refused transfer holds nothing")

    local written, why = backend.write(inRoot("lane/absent/deep.bin"), "x")
    assert(
        not written and type(why) == "string" and #why > 0,
        "a write that fails on the worker carries its reason back"
    )
    test.eq(backend.pendingTransfers(), 0)
end

-- The point of the whole design: the call below is the same call in both cases.
-- With no handler it waits by sleeping; with one installed it hands the wait to
-- the handler, which drives the registered pump and resumes it.
function M.aTransferParksUnderAHandlerAndBlocksWithoutOne()
    local files = ready()
    local backend = require("nupp.runtime.provider.nativefiles")
    local suspension = require("nupp.runtime.standardcoroutine").value
    local suspensionHost = require("coroutine.host")
    assert(files.mkdir(inRoot("parking")))
    assert(backend.write(inRoot("parking/payload.bin"), ("park"):rep(40000)))

    local parked, pumped = nil, 0
    local handler = {
        park = function(_self, waiting)
            parked = waiting.operation
            while not waiting:ready() do
                pumped = pumped + suspensionHost.poll()
            end
        end,
    }
    local installation = suspensionHost.install(handler)
    local answers = {pcall(backend.read, inRoot("parking/payload.bin"))}
    installation:close()
    assert(answers[1], answers[2])
    test.eq(#answers[2], 160000, "the parked read answered its bytes")
    if parked ~= nil then
        test.eq(parked, "file transfer", "the handler was told what it was waiting for")
        assert(pumped > 0, "the handler drove the pump the library registered")
    else
        test.eq(pumped, 0, "a transfer already ready before suspension needs no handler work")
    end
    test.eq(backend.pendingTransfers(), 0)

    -- Without a handler the same call still answers, having waited by itself.
    test.eq(#assert(backend.read(inRoot("parking/payload.bin"))), 160000)
    test.eq(backend.pendingTransfers(), 0)
end

-- Losing a race is the ordinary way a transfer is abandoned, and the lane's
-- budget is bounded, so a cancelled transfer keeping its slot would shrink what
-- every later transfer may hold until nothing fits at all.
function M.aCancelledTransferGivesItsLaneSlotBack()
    local files = ready()
    local backend = require("nupp.runtime.provider.nativefiles")
    local tasks = require("coroutine")
    assert(files.mkdir(inRoot("cancel")))
    assert(backend.write(inRoot("cancel/large.bin"), ("drop"):rep(1000000)))
    test.eq(backend.pendingTransfers(), 0, "the lane starts idle")

    -- The read is large enough to park, and the other branch settles at once, so
    -- the race abandons the read while it is still in flight.
    local value = tasks.race({
        function()
            -- A race branch answers one value; `assert` would pass on the nil reason
            -- too.
            return (assert(backend.read(inRoot("cancel/large.bin"))))
        end,
        function()
            return "settled first"
        end,
    })
    assert(value ~= nil)
    test.eq(backend.pendingTransfers(), 0, "a cancelled transfer gave its slot and bytes back")
end

function M.anAtomicWriteLeavesTheDestinationAloneWhenItFails()
    local files = ready()
    assert(files.mkdir(inRoot("atomic")))
    assert(writeFile(inRoot("atomic/kept.txt"), "original"))
    local written, reason = files.writeatomic(inRoot("atomic/absent/kept.txt"), "replacement")
    assert(not written and isIoError(reason))
    test.eq(assert(readFile(inRoot("atomic/kept.txt"))), "original")
end

function M.anOpenFileReadsAndWritesThroughTheSharedContracts()
    local files = ready()
    test.eq(files.pendingtransfers, nil, "transfer accounting is private")
    test.eq(files.open, nil, "file acquisition belongs to io.open")
    test.eq(files.lines, nil, "file iteration belongs to io.lines and Reader:lines")
    test.eq(files.read, nil, "whole-file reads use io.open")
    test.eq(files.write, nil, "whole-file writes use io.open")
    test.eq(files.append, nil, "append uses io.open with append mode")
    assert(files.mkdir(inRoot("handles")))
    assert(writeFile(inRoot("handles/source.txt"), "hello world!"))

    local file = assert(io.open(inRoot("handles/source.txt"), "rb"))
    test.eq(assert(file:seek("end")), 12)
    test.eq(assert(file:seek("set", 0)), 0)
    local reader = file:reader()
    test.eq(reader:read(5), "hello")
    test.eq(assert(file:seek()), 5)
    test.eq(reader:read(64), " world!")
    test.eq(reader:read(64), "", "a byte reader at the end returns no bytes")
    test.eq(file:read(1), nil, "Lua file reads return nil at EOF")
    test.eq(assert(file:seek("set", 6)), 6)
    test.eq(reader:read(5), "world")
    test.eq(assert(file:seek("end", -1)), 11)
    test.eq(reader:read(4), "!")
    local invalid, invalidReason = file:seek("cur", -100)
    test.eq(invalid, nil)
    assert(type(invalidReason) == "string", "a seek before the start returns a reason")
    test.eq(assert(file:seek()), 12, "a failed seek leaves the cursor unchanged")
    reader:close()
    test.eq(io.type(file), "file", "closing a byte view leaves its file open")
    assert(file:close())
    test.eq(io.type(file), "closed file")
    test.raises(
        function()
            file:read(1)
        end,
        "closed file"
    )

    local out = assert(io.open(inRoot("handles/sink.txt"), "wb"))
    local writer = out:writer()
    assert(writer:write("prefix:"))
    assert(writer:flush())
    writer:close()
    assert(out:close(), "a Lua file close reports success")
    test.eq(assert(readFile(inRoot("handles/sink.txt"))), "prefix:")

    local missing, reason = io.open(inRoot("handles/absent"))
    test.eq(missing, nil)
    assert(type(reason) == "string" and #reason > 0)
    local accepted, invalidFile, invalidMode = pcall(io.open, inRoot("handles/sink.txt"), "sideways")
    assert(not accepted or invalidFile == nil and type(invalidMode) == "string", "invalid modes are refused")
end

function M.privateFileProviderRejectsInexactSeekPositions()
    local files = ready()
    assert(writeFile(inRoot("seek-integer-boundary"), "x"))
    local nativeFiles = require("nupp.runtime.provider.nativefiles")
    local file = assert(nativeFiles.open(inRoot("seek-integer-boundary")))
    test.eq(assert(file:seek(9007199254740991)), 9007199254740991)
    local overflow, overflowReason = file:seek(1, "current")
    test.eq(overflow, nil)
    assert(isIoError(overflowReason), "a seek beyond the exact integer range returns a reason")
    test.eq(assert(file:position()), 9007199254740991, "a refused seek leaves the cursor unchanged")
    file:close()
end

function M.transfersMoveBytesWithoutAStringInBetween()
    local files = ready()
    assert(files.mkdir(inRoot("transfer")))
    local payload = ("chunk"):rep(60000)
    assert(writeFile(inRoot("transfer/big.bin"), payload))

    local source = assert(io.open(inRoot("transfer/big.bin")))
    local sink = assert(io.open(inRoot("transfer/copy.bin"), "w"))
    local reader = source:reader()
    local writer = sink:writer()
    test.eq(reader:transferto(writer), #payload)
    reader:close()
    writer:close()
    source:close()
    sink:close()
    test.eq(assert(readFile(inRoot("transfer/copy.bin"))), payload)

    local file = assert(io.open(inRoot("transfer/big.bin")))
    local buffer = buffers.Buffer.create()
    local reader = file:reader()
    test.eq(reader:readinto(buffer, 0, 5), 5)
    test.eq(buffer:tostring(), "chunk")
    test.eq(reader:readinto(buffer, 8, 5), 5, "a read lands where it is told")
    test.eq(buffer:tostring(), "chunk\0\0\0chunk", "the gap before an offset reads as zero bytes")
    reader:close()
    file:close()
end

function M.aBufferWritesIntoAFileFromItsOwnStorage()
    local files = ready()
    assert(files.mkdir(inRoot("frombuffer")))
    local buffer = buffers.Buffer.create("prefix:body")
    local file = assert(io.open(inRoot("frombuffer/out.bin"), "w"))
    local writer = file:writer()
    local bytes = buffer:span()
    test.eq(writer:writespan(bytes:slice(1, 7)), 7)
    test.eq(writer:writespan(bytes:slice(8)), 4)
    local prefix = buffer:span(1, 3)
    test.eq(writer:writespan(prefix), 3)
    assert(writer:flush())
    writer:close()
    file:close()
    test.eq(assert(readFile(inRoot("frombuffer/out.bin"))), "prefix:bodypre")
    test.raises(
        function()
            local other = assert(io.open(inRoot("frombuffer/out.bin"), "w"))
            local writer = other:writer()
            local ok, reason = pcall(function()
                writer:writespan(bytes:slice(9, 48))
            end)
            writer:close()
            other:close()
            assert(ok, reason)
        end,
        "out of bounds"
    )
end

-- Every line a line reader answers, and the reason it stopped.
local function readLines(lines)
    local seen = {}
    while true do
        local line, reason = lines:read()
        if line == nil then
            lines:close()
            return seen, reason
        end
        seen[#seen + 1] = line
    end
end

local function readFileLines(path, limit)
    local file, reason = io.open(path, "rb")
    if file == nil then
        return nil, reason
    end
    local lines = file:reader():lines(limit)
    local seen, lineReason = readLines(lines)
    file:close()

    return seen, lineReason
end

function M.linesSplitOnEitherPlatformsEnding()
    local files = ready()
    assert(files.mkdir(inRoot("lines")))
    assert(writeFile(inRoot("lines/mixed.txt"), "one\ntwo\r\nthree"))
    local seen, reason = readFileLines(inRoot("lines/mixed.txt"))
    test.eq(table.concat(seen, "|"), "one|two|three")
    test.eq(reason, nil, "the end of the file has no reason")

    assert(writeFile(inRoot("lines/trailing.txt"), "only\n"))
    local trailing = readFileLines(inRoot("lines/trailing.txt"))
    test.eq(#trailing, 1, "a trailing newline does not make an empty line")
    test.eq(trailing[1], "only")

    assert(writeFile(inRoot("lines/empty.txt"), ""))
    test.eq(#readFileLines(inRoot("lines/empty.txt")), 0, "an empty file has no lines")

    assert(writeFile(inRoot("lines/long.txt"), ("x"):rep(20) .. "\n"))
    local long, longReason = readFileLines(inRoot("lines/long.txt"), 8)
    test.eq(#long, 0)
    assert(type(longReason) == "string", "a line past the limit answers a reason")

    local missing, missingReason = readFileLines(inRoot("lines/absent"))
    test.eq(missing, nil)
    assert(type(missingReason) == "string" and #missingReason > 0, "a missing file returns its error")
end

-- A directory is the deterministic way to make the first read fail on a handle
-- that opened: POSIX opens one for reading and refuses to read it.
function M.aFailingReadAnswersAReasonRatherThanEndingTheLines()
    local files = ready()
    assert(files.mkdir(inRoot("lines")))
    local file = io.open(inRoot("lines"), "rb")
    if file ~= nil then
        local seen, reason = readLines(file:reader():lines())
        file:close()
        test.eq(#seen, 0)
        assert(type(reason) == "string" and #reason > 0, "a failed read answers the platform's reason")
    end
end

-- A read that fails partway through a file is not its end. The line reader is
-- composed from the provider's open file, so a provider cannot answer a failure
-- as a clean stop: it arrives as nil and the reason, after the lines before it.
function M.aReadThatFailsMidFileSurfacesFromTheLineReader()
    local closed, reads = 0, 0
    local reader = {
        read = function(_, count)
            reads = reads + 1
            if reads == 1 then
                return ("one\ntw"):sub(1, count)
            end

            return nil, "the disk went away"
        end,
        close = function()
            closed = closed + 1
        end,
    }
    local lines = require("nupp.io.internal.bytes").Reader.lines(reader)
    test.eq(lines:read(), "one")
    local line, reason = lines:read()
    test.eq(line, nil, "a failed read is not a line")
    test.eq(reason, "the disk went away", "and it is not the end of the file either")
    lines:close()
    test.eq(closed, 1, "closing the lines closes the reader they took")
end

function M.argumentsAreCheckedAtTheCallSite()
    local files = ready()
    test.raises(
        function()
            files.stat(42)
        end,
        "must be a path or a string"
    )
    test.raises(
        function()
            os.rename(inRoot("a"), true)
        end,
        "string expected"
    )
    test.raises(
        function()
            files.symlink(inRoot("a"), inRoot("b"), "sideways")
        end,
        "symlink kind"
    )
    test.raises(
        function()
            files.mktemp(7)
        end,
        "prefix must be a string"
    )
    test.raises(
        function()
            files.mktempdir(nil, true)
        end,
        "suffix must be a string"
    )
    test.raises(
        function()
            files.appdir("documents")
        end,
        "expected \"config\""
    )
    test.raises(
        function()
            os.remove(inRoot("a"), "yes")
        end,
        "recursive must be a boolean"
    )
    assert(writeFile(inRoot("integer-boundary"), "x"))
    local file = assert(require("nupp.runtime.provider.nativefiles").open(inRoot("integer-boundary")))
    test.raises(
        function()
            file:seek(math.huge)
        end,
        "must be an integer"
    )
    test.raises(
        function()
            file:read(math.huge)
        end,
        "must be an integer"
    )
    file:close()
end

function M.aPathObjectIsAcceptedWhereverAStringIs()
    local files = ready()
    local asPath = setmetatable({_text = inRoot("viapath")}, {
        __index = {
            tostring = function(self)
                return self._text
            end
        },
    })
    assert(files.mkdir(asPath))
    test.eq(files.stat(inRoot("viapath")), "directory")
    test.eq(files.exists(asPath), true)
end

function M.theProviderIsSelectedOnlyByReachingIt()
    test.eq(native.forModule("io.internal.files"), "runtime.files")
    test.eq(native.forModuleMember("nupp.runtime.standardos", "stat"), "runtime.files")
    test.eq(native.forModuleMember("nupp.runtime.standardos", "list"), "runtime.files")
    test.eq(native.forModuleMember("nupp.runtime.standardos", "monotonic"), nil)
    test.eq(native.forModule("nupp.runtime.provider.nativefiles"), "native.files")
    local feature = assert(native.feature("native.files"))
    -- The provider calls the operating system itself, so selecting it stages no
    -- Rust library and asks nothing of the native ABI loader.
    test.eq(feature.providerFeature, nil)
    test.eq(feature.providerDriver, nil)
    test.eq(feature.provider, nil)
    test.eq(feature.library, nil)
    test.eq(feature.runtimeModule, "nupp.runtime.provider.nativefiles")
    test.eq(
        table.concat(feature.requires or {}, ","),
        "runtime.files,native.path,stdlib.io,runtime.spanview,runtime.suspension"
    )
    assert(
        not stdlib.bootstrap({
            ["native.files"] = true
        }):find("nuppNativeFiles", 1, true),
        "selecting the feature installs no files ABI"
    )
    for _, name in ipairs({"nativefiles", "nativepath", "nativefsposix", "nativefswindows", "nativefslane", "nativefsglob"}) do
        local handle = assert(io.open("src/nupp/runtime/provider/" .. name .. ".nupp", "rb"))
        local source = handle:read("*a")
        handle:close()
        assert(not source:find("nuppNativeFile", 1, true), name .. " calls none of the Rust files exports")
        assert(not source:find("nupp.runtime.native", 1, true), name .. " does not load the Rust provider")
    end
end

function M.appPathsAreScopedPortableAndStable()
    local files = ready()
    test.eq(files.appid(), nil)
    local missing, reason = files.appdir("data")
    test.eq(missing, nil)
    assert(tostring(reason):find("setappid", 1, true))

    local app = "portable-files-" .. tostring(math.random(1, 1e9))
    files.setappid("nupp", app)
    local organization, selected = files.appid()
    test.eq(organization, "nupp")
    test.eq(selected, app)
    local apppaths = require("io.internal.files.path")
    test.eq(apppaths.encodeid("Tecs"), "Tecs")
    test.eq(apppaths.encodeid("a%b"), "a%25b")
    test.eq(apppaths.encodeid("a/b\\c"), "a%2Fb%5Cc")
    test.eq(apppaths.encodeid("line\nfeed"), "line%0Afeed")
    test.eq(apppaths.encodeid("tail."), "tail%2E")
    test.eq(apppaths.encodeid("NUL"), "%4EUL")
    test.eq(apppaths.encodeid("COM¹"), "%43OM¹")
    assert(apppaths.encodeid("/") ~= apppaths.encodeid("%2F"), "identity escaping remains reversible")
    local returned = assert(files.appdir("cache"))
    assert(getmetatable(returned) == require("io.internal.pathtypes").Path)
    assert(files.remove(returned, true))
    local data = apppaths.native(root, "nupp", app)

    assert(getmetatable(data) == require("io.internal.pathtypes").Path)
    assert(files.mkdir(data))
    local note = assert(data:resolve("notes.txt"))
    do
        local handle = assert(io.open(note, "w"))
        assert(handle:write("unified path"))
        assert(handle:close())
    end
    test.eq(assert(readFile(note)), "unified path")
    test.eq(note:parent(), data)
    local canonical = assert(note:canonicalize())
    test.eq(assert(readFile(canonical)), "unified path")
    local safe = data:join("save files", "slot-1.dat")
    assert(safe:tostring():find("save files", 1, true))
    for _, invalid in ipairs({
        "",
        ".",
        "..",
        "/etc",
        "C:\\Windows",
        "a/b",
        "a\\b",
        "NUL",
        "COM1.txt",
        "LPT9",
        "COM¹",
        "LPT³.txt",
        "bad?name",
        "bad:name",
        "bad\0name",
        "bad\31name",
        "tail.",
        "tail ",
    }) do
        test.raises(
            function()
                data:join(invalid)
            end,
            "application path component"
        )
    end

    files.setappid("nupp", app .. "-next")
    local nextData = apppaths.native(root, "nupp", app .. "-next")
    assert(nextData:tostring() ~= data:tostring(), "changing identity selects another root")
    assert(data:join("old"):tostring():find(app, 1, true), "an existing path retains its identity")
end

function M.nativeCapabilitiesAreReportedOnce()
    local files = ready()
    local caps = os.info().fs
    for _, name in ipairs({
        "available",
        "arbitrarypaths",
        "symlinks",
        "glob",
        "rename",
        "atomicwrite",
        "tmppaths",
        "concurrentopenhandles",
        "cwd",
        "persist",
    }) do
        test.eq(caps[name], true, "native capability " .. name)
    end
    assert(rawequal(os.info().fs, caps), "the report is built once and shared")
    assert(files.persiststorage())
end

----------------------------------------------------------------------------
-- The provider's own mechanisms, each case the former Rust crate's tests held
----------------------------------------------------------------------------

local onWindows = package.config:sub(1, 1) == "\\"

local function platformSystem()
    if onWindows then
        return require("nupp.runtime.provider.nativefswindows")
    end
    return require("nupp.runtime.provider.nativefsposix")
end

function M.globGrammarIsExplicitAndBytewise()
    ready()
    local globbing = require("nupp.runtime.provider.nativefsglob")
    assert(globbing.matchesName("a?c", "abc"))
    assert(globbing.matchesName("[!a]bc", "xbc"))
    assert(globbing.matchesName("[a-c]x", "bx"))
    assert(not globbing.matchesName("[!a]bc", "abc"))
    assert(globbing.matchesName("*.nupp", "file.nupp"))
    assert(not globbing.matchesName("*.nupp", "file.lua"))
    assert(globbing.matchesName("caf\233*", "caf\233.txt"), "a byte that is not UTF-8 matches itself")
    assert(globbing.parse("root/**/file?.nupp", false))
    test.eq(select(3, globbing.parse("root/a**b", false)), "a recursive wildcard must be a whole path component")
    test.eq(select(3, globbing.parse("root/[", false)), "the pattern has an unclosed [")
end

function M.longLiteralGlobPatternsNeitherOverflowNorMatch()
    local files = ready()
    local depth = require("nupp.runtime.provider.nativefsglob").MAX_WALK_DEPTH
    local deep = ("a/"):rep(depth - 1) .. "b"
    test.eq(#assert(files.glob(deep)), 0)
    local refused, reason = files.glob(("a/"):rep(depth) .. "b")
    test.eq(refused, nil)
    assert(isIoError(reason), "a pattern longer than any reachable path is refused")
end

function M.repeatedRecursiveWildcardsReadEachDirectoryABoundedNumberOfTimes()
    local files = ready()
    local globbing = require("nupp.runtime.provider.nativefsglob")
    local base = inRoot("glob-repeated")
    local deepest = base
    for level = 0, 11 do
        deepest = deepest .. "/d" .. level
    end
    assert(files.mkdir(deepest))
    write(deepest .. "/x", "x")
    local system = platformSystem()
    local expected = assert(globbing.expand(base .. "/**/x", system, onWindows))
    test.eq(#expected, 1)
    for _, pattern in ipairs({base .. "/" .. ("**/"):rep(8) .. "x", base .. "/**/d3/**/d7/**/x"}) do
        local found, reason, reads = globbing.expand(pattern, system, onWindows)
        assert(found, reason)
        test.eq(table.concat(found, "|"), table.concat(expected, "|"))
        assert(reads < 200, pattern .. " read directories " .. reads .. " times")
    end
end

function M.recursiveGlobMatchesAreSortedAndUnique()
    local files = ready()
    assert(files.mkdir(inRoot("glob-sorted/nested/deep")))
    write(inRoot("glob-sorted/root.nupp"), "root")
    write(inRoot("glob-sorted/nested/child.nupp"), "child")
    write(inRoot("glob-sorted/nested/deep/leaf.nupp"), "leaf")
    local found = assert(files.glob(inRoot("glob-sorted/**/**/[a-z]*.nupp")))
    test.eq(#found, 3)
    for index = 2, #found do
        assert(found[index - 1]:tostring() < found[index]:tostring(), "matches are sorted and unique")
    end
end

function M.aRecursiveGlobDoesNotFollowDirectoryLinks()
    local files = ready()
    assert(files.mkdir(inRoot("glob-links/real")))
    write(inRoot("glob-links/real/file.txt"), "x")
    assert(files.symlink(inRoot("glob-links"), inRoot("glob-links/real/loop"), "directory"))
    test.eq(#assert(files.glob(inRoot("glob-links/**/*.txt"))), 1)
end

function M.theLaneEnforcesItsRequestAndByteLimits()
    local files = ready()
    local lane = require("nupp.runtime.provider.nativefslane")
    assert(files.mkdir(inRoot("limits")))
    -- A one-byte step leaves every two-byte write pending after its first step, so
    -- each one holds its admission until it is cancelled.
    local requests, bytes, requestBytes, step = lane.configure(4, 7, 3, 1)
    local held = {}
    local ok, problem = pcall(function()
        for index = 1, 3 do
            held[index] = assert(lane.submitWrite(inRoot("limits/" .. index .. ".bin"), "ab", "replace"))
            test.eq(lane.status(held[index]), lane.PENDING)
        end
        test.eq(select(2, lane.admitted()), 6)
        local refused, reason = lane.submitWrite(inRoot("limits/over.bin"), "ab", "replace")
        test.eq(refused, nil)
        test.eq(reason, "transfers in flight would hold more than 7 bytes")
        local large, why = lane.submitWrite(inRoot("limits/large.bin"), "abcd", "replace")
        test.eq(large, nil)
        test.eq(why, "the transfer is larger than the 3-byte limit")
        held[4] = assert(lane.submitWrite(inRoot("limits/4.bin"), "a", "replace"))
        test.eq(lane.status(held[4]), lane.READY, "a write that fits one step settles on submission")
        lane.release(held[4])
        held[4] = assert(lane.submitWrite(inRoot("limits/4.bin"), "", "replace"))
        held[5] = assert(lane.submitWrite(inRoot("limits/5.bin"), "", "replace"))
        local crowded, crowdedReason = lane.submitCopy(inRoot("limits/4.bin"), inRoot("limits/6.bin"))
        test.eq(crowded, nil)
        test.eq(crowdedReason, "more than 4 transfers are in flight")
    end)
    for _, transfer in pairs(held) do
        lane.cancel(transfer)
        lane.release(transfer)
    end
    lane.configure(requests, bytes, requestBytes, step)
    assert(ok, problem)
    test.eq(select(1, lane.admitted()), 0, "every cancelled transfer gave its slot back")
    test.eq(select(2, lane.admitted()), 0, "and its bytes")
    test.eq(lane.pending(), 0)
end

function M.aCancelledAtomicWriteLeavesNoTemporaryAndTheDestinationAlone()
    local files = ready()
    local lane = require("nupp.runtime.provider.nativefslane")
    assert(files.mkdir(inRoot("atomic-cancel")))
    assert(writeFile(inRoot("atomic-cancel/kept.txt"), "original"))
    local requests, bytes, requestBytes, step = lane.configure(128, 1048576, 1048576, 1)
    local transfer = lane.submitWrite(inRoot("atomic-cancel/kept.txt"), "replacement", "atomic")
    lane.configure(requests, bytes, requestBytes, step)
    assert(transfer)
    test.eq(lane.status(transfer), lane.PENDING)
    assert(lane.cancel(transfer))
    test.eq(lane.status(transfer), lane.CANCELED)
    assert(not lane.cancel(transfer), "a settled transfer cannot be cancelled again")
    test.eq(select(2, lane.take(transfer)), "the transfer was canceled")
    lane.release(transfer)
    test.eq(assert(readFile(inRoot("atomic-cancel/kept.txt"))), "original")
    for name in files.list(inRoot("atomic-cancel")) do
        test.eq(name, "kept.txt", "the cancelled write removed its temporary")
    end
end

function M.anAtomicWriteReplacesContentsAndKeepsTheModeItFound()
    local files = ready()
    assert(files.mkdir(inRoot("atomic-mode")))
    assert(writeFile(inRoot("atomic-mode/value.bin"), "old"))
    assert(files.writeatomic(inRoot("atomic-mode/value.bin"), "new"))
    test.eq(assert(readFile(inRoot("atomic-mode/value.bin"))), "new")
    for name in files.list(inRoot("atomic-mode")) do
        assert(not name:find("^%.nupp%-write%-"), "no temporary is left behind: " .. name)
    end
    if not onWindows then
        local system = platformSystem()
        assert(writeFile(inRoot("atomic-mode/plain.bin"), "plain"))
        assert(files.writeatomic(inRoot("atomic-mode/atomic.bin"), "atomic"))
        test.eq(
            system.permissions(inRoot("atomic-mode/atomic.bin")),
            system.permissions(inRoot("atomic-mode/plain.bin")),
            "a new file gets the mode a plain write gives"
        )
        os.execute("chmod 640 '" .. inRoot("atomic-mode/value.bin") .. "'")
        assert(files.writeatomic(inRoot("atomic-mode/value.bin"), "newer"))
        test.eq(system.permissions(inRoot("atomic-mode/value.bin")), tonumber("640", 8), "a replacement keeps the mode")
    end
    test.eq(platformSystem().parent("bare.txt"), ".", "a bare name's temporary goes in the working directory")
end

function M.aRecursiveRemoveNeverLeavesTheTree()
    local files = ready()
    assert(files.mkdir(inRoot("remove-links/tree/sub")))
    assert(files.mkdir(inRoot("remove-links/outside")))
    write(inRoot("remove-links/outside/victim"), "outside")
    write(inRoot("remove-links/tree/sub/victim"), "inside")
    assert(files.symlink(inRoot("remove-links/outside"), inRoot("remove-links/tree/link"), "directory"))
    assert(os.remove(inRoot("remove-links/tree"), true))
    assert(not files.exists(inRoot("remove-links/tree")))
    test.eq(assert(readFile(inRoot("remove-links/outside/victim"))), "outside", "a link inside the tree is not followed")
end

function M.aRecursiveRemoveNeverFollowsADirectorySwappedForALink()
    local files = ready()
    if onWindows then
        test.suite.skip("the swap is a POSIX descriptor race")
    end
    local system = platformSystem()
    assert(files.mkdir(inRoot("remove-race/tree/sub")))
    assert(files.mkdir(inRoot("remove-race/outside")))
    write(inRoot("remove-race/tree/sub/victim"), "inside")
    write(inRoot("remove-race/outside/victim"), "outside")
    system.setBeforeDescend(function(name)
        if name == "sub" then
            assert(os.rename(inRoot("remove-race/tree/sub"), inRoot("remove-race/aside")))
            assert(files.symlink(inRoot("remove-race/outside"), inRoot("remove-race/tree/sub")))
        end
    end)
    local removed, reason = pcall(os.remove, inRoot("remove-race/tree"), true)
    system.setBeforeDescend(nil)
    test.eq(assert(readFile(inRoot("remove-race/outside/victim"))), "outside")
    assert(removed, reason)
    assert(not files.exists(inRoot("remove-race/tree")))
end

function M.namesThatAreNotUtf8RoundTripAsBytes()
    local files = ready()
    local name = "caf\233.txt"
    if onWindows then
        local kind, _, _, _, reason = files.stat(inRoot(name))
        test.eq(kind, nil)
        assert(tostring(reason):find("not valid UTF-8", 1, true), "Windows names are UTF-8: " .. tostring(reason))
        return
    end
    assert(files.mkdir(inRoot("bytes")))
    local written = writeFile(inRoot("bytes/" .. name), "x")
    if not written then
        -- APFS refuses a name that is not UTF-8; only Linux filesystems take one.
        test.suite.skip("this filesystem refuses names that are not UTF-8")
    end
    test.eq(files.stat(inRoot("bytes/" .. name)), "file")
    local listed = {}
    for entry in files.list(inRoot("bytes")) do
        listed[#listed + 1] = entry
    end
    test.eq(table.concat(listed, "|"), name)
    local found = assert(files.glob(inRoot("bytes/*.txt")))
    test.eq(#found, 1)
    assert(found[1]:tostring():sub(-#name) == name, "a glob answers the name's own bytes")
    local canonical = assert(require("nupp.runtime.provider.nativepath").canonicalize(inRoot("bytes/" .. name)))
    test.eq(canonical:sub(-#name), name)
end

function M.anAppendCursorReportsTheEndWhereTheWriteLanded()
    ready()
    local nativeFiles = require("nupp.runtime.provider.nativefiles")
    assert(writeFile(inRoot("append-cursor.bin"), "prefix"))
    local file = assert(nativeFiles.open(inRoot("append-cursor.bin"), "a+"))
    test.eq(assert(file:position()), 0)
    assert(file:write(":body"))
    test.eq(assert(file:position()), 11)
    test.eq(assert(file:seek(-4, "current")), 7)
    test.eq(file:read(4), "body")
    assert(file:flush())
    file:close()

    local update = assert(nativeFiles.open(inRoot("append-cursor.bin"), "r+"))
    test.eq(update:read(5), "prefi")
    local refused, reason = update:seek(-100, "current")
    test.eq(refused, nil)
    assert(isIoError(reason))
    test.eq(assert(update:position()), 5, "a failed seek leaves the cursor alone")
    test.eq(assert(update:seek(-1, "end")), 10)
    test.eq(update:read(2), "y")
    update:close()
end

function M.temporaryNameFragmentsCannotEscapeTheSelectedDirectory()
    local files = ready()
    local nativeFiles = require("nupp.runtime.provider.nativefiles")
    assert(files.mkdir(inRoot("temporary-fragments")))
    local escaped, reason = nativeFiles.createTemporary(false, "../outside-", nil, inRoot("temporary-fragments"))
    test.eq(escaped, nil)
    test.eq(reason, "temporary name fragments must not contain a path separator")
    test.eq(nativeFiles.createTemporary(false, nil, "/outside", inRoot("temporary-fragments")), nil)
    for _ in files.list(inRoot("temporary-fragments")) do
        error("a refused temporary created nothing")
    end
    local made = assert(nativeFiles.createTemporary(true, "directory-", "", inRoot("temporary-fragments")))
    test.eq(files.stat(made:tostring()), "directory")
    assert(made:tostring():find("directory-", 1, true))
    made:close()
end

function M.theReadOnlyStateCanBeSetAndCleared()
    ready()
    local nativeFiles = require("nupp.runtime.provider.nativefiles")
    assert(writeFile(inRoot("read-only.txt"), "value"))
    assert(nativeFiles.setReadOnly(inRoot("read-only.txt"), true))
    test.eq(select(4, nativeFiles.stat(inRoot("read-only.txt"), true)), true)
    assert(nativeFiles.setReadOnly(inRoot("read-only.txt"), false))
    test.eq(select(4, nativeFiles.stat(inRoot("read-only.txt"), true)), false)
end

function M.applicationBasesFollowEachPlatformContract()
    ready()
    local nativeFiles = require("nupp.runtime.provider.nativefiles")
    local environment = {
        HOME = "/home/test",
        USERPROFILE = "C:/Users/Test",
        APPDATA = "C:\\Users\\Test\\AppData\\Roaming",
        LOCALAPPDATA = "C:/Users/Test/AppData/Local",
        XDG_CONFIG_HOME = "/xdg/config",
        XDG_DATA_HOME = "relative/data",
    }
    local function read(name)
        return environment[name]
    end
    local expected = {
        windows = {"C:/Users/Test/AppData/Roaming", "C:/Users/Test/AppData/Local", "C:/Users/Test/AppData/Local/Temp"},
        apple = {"/home/test/Library/Preferences", "/home/test/Library/Application Support", "/home/test/Library/Caches"},
        xdg = {"/xdg/config", "/home/test/.local/share", "/home/test/.cache"},
    }
    for platform, bases in pairs(expected) do
        local distinct = {}
        for which = 0, 2 do
            local base = assert(nativeFiles.applicationBase(which, platform, read))
            test.eq(base, bases[which + 1], platform .. " base " .. which)
            assert(not distinct[base], "three kinds, three directories")
            distinct[base] = true
        end
        test.eq(select(2, nativeFiles.applicationBase(3, platform, read)), "unknown application base")
    end
    local function nothing()
        return nil
    end
    test.eq(select(2, nativeFiles.applicationBase(0, "xdg", nothing)), "the home directory is not set")
end

function M.whereThingsLiveIsAnsweredByTheSystem()
    local files = ready()
    local nativeFiles = require("nupp.runtime.provider.nativefiles")
    local nativePath = require("nupp.runtime.provider.nativepath")
    local executable = assert(nativeFiles.executablePath())
    test.eq(files.stat(executable), "file")
    local home = assert(nativeFiles.userFolder(0))
    test.eq(files.stat(home), "directory")
    test.eq(select(2, nativeFiles.userFolder(9)), "unknown user folder")
    local cwd = assert(nativePath.cwd())
    test.eq(files.stat(cwd), "directory")
    assert(not cwd:find("\\", 1, true), "paths come back with forward slashes")
    local canonical = assert(nativePath.canonicalize("."))
    test.eq(files.stat(canonical), "directory")
    local missing, reason = nativePath.canonicalize(inRoot("absent/deeper"))
    test.eq(missing, nil)
    assert(isIoError(require("nupp.io").toError(reason), "notfound"), tostring(reason))
end

return M
