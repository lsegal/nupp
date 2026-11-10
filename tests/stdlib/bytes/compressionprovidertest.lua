local state = require("helpers.providerstate")
local io2 = require("io")
local ffi = require("ffi")
local M = {}

local NEED_INPUT = 1
local NEED_OUTPUT = 2
local FINISHED = 3

local function nativeProvider()
    return require("nupp.runtime.provider.nativecompression")
end

local function view(pointer, count)
    return {
        count = count,
        ref = function()
            return pointer
        end,
    }
end

local function provider(name, decoder, priority)
    return {
        priority = priority,
        formats = {
            [name] = {
                name = name,
                createencoder = function()
                    error("encoder is not used")
                end,
                createdecoder = decoder,
            },
        },
    }
end

local function decoder(finishInput)
    return function()
        return {
            read = function(_, input)
                return input.count, 0, NEED_INPUT
            end,
            finishinput = finishInput,
            close = function()
            end,
        }
    end
end

function M.compressionNamesUseCanonicalKeysOnly()
    local contract = require("nupp.compression.contracts")
    assert(contract.needinput == NEED_INPUT and contract.needoutput == NEED_OUTPUT and contract.finished == FINISHED)
    assert(contract.NEED_INPUT == nil and contract.NEED_OUTPUT == nil and contract.FINISHED == nil)
    local load = state.family("compression", {})
    local format = load("bytes").compress("gzip")
    assert(type(format.reader) == "function" and format.newReader == nil)
    assert(type(format.writer) == "function" and format.newWriter == nil)
    local native = nativeProvider()
    local implementation = native.formats.gzip
    assert(type(implementation.createencoder) == "function" and implementation.createEncoder == nil)
    assert(type(implementation.createdecoder) == "function" and implementation.createDecoder == nil)
    local decoder = implementation:createdecoder()
    assert(type(decoder.finishinput) == "function" and decoder.finishInput == nil)
    decoder:close()
end

function M.decoderEofCanFillMoreThanOneOutputSpan()
    local calls = 0
    local load = state.family("compression", {
        provider(
            "fixture",
            decoder(function()
                calls = calls + 1
                if calls == 1 then
                    return 1, NEED_OUTPUT
                end

                return 0, FINISHED
            end)
        ),
    })
    local reader = load("bytes").compress("fixture"):reader(io2.Reader.of("input"), {
        workspacebytes = 1,
        unbounded = true
    })
    assert(#assert(reader:read(1)) == 1)
    assert(reader:read(1) == "")
    reader:close()
    assert(calls == 2)
end

function M.rejectsInvalidProviderAndSourceProgress()
    for _, finishInput in ipairs({
        function()
            return 2, FINISHED
        end,
        function()
            return 1, 99
        end,
    }) do
        local load = state.family("compression", {provider("fixture", decoder(finishInput))})
        local reader = load("bytes").compress("fixture"):reader(io2.Reader.of("input"), {
            workspacebytes = 1,
            unbounded = true
        })
        local bytes, reason = reader:read(1)
        assert(bytes == nil and reason:find("invalid progress", 1, true), tostring(reason))
        reader:close()
    end

    local load = state.family("compression", {
        provider(
            "fixture",
            decoder(function()
                return 0, FINISHED
            end)
        )
    })
    local source = {
        readspan = function(_, output)
            return output.count + 1
        end,
        close = function()
        end,
    }
    local reader = load("bytes").compress("fixture"):reader(source, {workspacebytes = 1, unbounded = true})
    local bytes, reason = reader:read(1)
    assert(bytes == nil and reason:find("source reader", 1, true), tostring(reason))
    reader:close()
end

function M.rejectsMalformedUntypedOptions()
    local load = state.family("compression", {
        provider(
            "fixture",
            decoder(function()
                return 0, FINISHED
            end)
        )
    })
    local format = load("bytes").compress("fixture")

    local function rejects(options, expected)
        local source = io2.Reader.of("")
        local ok, problem = pcall(format.reader, format, source, options)
        if ok then
            problem:close()
        else
            source:close()
        end
        assert(not ok and tostring(problem):find(expected, 1, true), tostring(problem))
    end

    rejects(false, "reader options must be a table")
    rejects({unbounded = "yes"}, "unbounded must be a boolean")
    rejects({maxexpansionratio = "1"}, "maxexpansionratio must be positive and finite")

    local destination = require("bytes").Buffer.create()
    local sink = destination:writer()
    local ok, problem = pcall(format.writer, format, sink, false)
    if ok then
        problem:close()
    else
        sink:close()
    end
    destination:close()
    assert(not ok and tostring(problem):find("writer options must be a table", 1, true), tostring(problem))
end

function M.cleanupContinuesAfterProviderReleaseFailure()
    local released = {encoder = 0, decoder = 0, destination = 0, source = 0}
    local fixture = {
        formats = {
            fixture = {
                name = "fixture",
                createencoder = function()
                    return {
                        finish = function()
                            return 0, FINISHED
                        end,
                        close = function()
                            released.encoder = released.encoder + 1
                            error("encoder release failed")
                        end,
                    }
                end,
                createdecoder = function()
                    return {
                        read = function(_, input)
                            return input.count, 0, NEED_INPUT
                        end,
                        finishinput = function()
                            return 0, FINISHED
                        end,
                        close = function()
                            released.decoder = released.decoder + 1
                            error("decoder release failed")
                        end,
                    }
                end,
            },
        },
    }
    local format = state.family("compression", {fixture})("bytes").compress("fixture")
    local destination = {
        flush = function()
            return true
        end,
        close = function()
            released.destination = released.destination + 1
        end,
    }
    local writer = format:writer(destination, {workspacebytes = 1})
    local ok, problem = pcall(writer.finish, writer)
    assert(not ok and tostring(problem):find("encoder release failed", 1, true), tostring(problem))
    assert(released.encoder == 1 and released.destination == 1)

    local source = {
        readspan = function()
            return 0
        end,
        close = function()
            released.source = released.source + 1
        end,
    }
    local reader = format:reader(source, {workspacebytes = 1, unbounded = true})
    ok, problem = pcall(reader.close, reader)
    assert(not ok and tostring(problem):find("decoder release failed", 1, true), tostring(problem))
    assert(released.decoder == 1 and released.source == 1)
end

function M.targetBindingRetainsCatalogWithoutDiscovery()
    local load, counts = state.family("compression")
    local api = load("bytes")
    assert(counts.resolutions == 0, "loading bytes does not initialize compression")
    assert(api.compression == nil and api.compressionformats == nil, "retired factories have no aliases")
    local names = api.formats("compression")
    assert(table.concat(names, ",") == "deflate-raw,gzip,zlib")
    names[1] = "changed"
    assert(api.formats("compression")[1] == "deflate-raw", "format listings are independent copies")
    assert(counts.resolutions == 0, "listing formats does not load native compression")
    assert(api.compress("gzip"))
    assert(api.compress("zlib"))
    assert(api.compress("deflate-raw"))
    assert(load("bytes") == api)
    assert(counts.resolutions == 1, "builtin implementation initializes once")
end

local function buffer(count)
    local storage = ffi.new("uint8_t[?]", math.max(count, 1))
    return storage, view(storage, count)
end

local function bytesOf(text)
    local storage = ffi.new("uint8_t[?]", math.max(#text, 1))
    ffi.copy(storage, text, #text)
    return storage
end

local function encode(name, input, chunk, options)
    local encoder = nativeProvider().formats[name]:createencoder(options)
    local answer = {}
    local at = 0
    local source = bytesOf(input)
    while at < #input do
        local storage, output = buffer(chunk)
        local consumed, written, status = encoder:write(view(source + at, #input - at), output)
        assert(consumed ~= nil, status)
        at = at + consumed
        answer[#answer + 1] = ffi.string(storage, written)
    end
    while true do
        local storage, output = buffer(chunk)
        local written, status = encoder:finish(output)
        answer[#answer + 1] = ffi.string(storage, written)
        if status == FINISHED then
            break
        end
    end
    encoder:close()

    return table.concat(answer)
end

local function decode(name, input, chunk, options)
    local decoder = nativeProvider().formats[name]:createdecoder(options)
    local answer = {}
    local at = 0
    local source = bytesOf(input)
    while at < #input do
        local storage, output = buffer(chunk)
        local consumed, written, status, reason = decoder:read(view(source + at, #input - at), output)
        if consumed == nil then
            decoder:close()
            return nil, reason
        end
        at = at + consumed
        answer[#answer + 1] = ffi.string(storage, written)
        if status == FINISHED then
            assert(at == #input, "a finished stream left input unread")
            decoder:close()
            return table.concat(answer)
        end
    end
    while true do
        local storage, output = buffer(chunk)
        local written, status, reason = decoder:finishinput(output)
        if written == nil then
            decoder:close()
            return nil, reason
        end
        answer[#answer + 1] = ffi.string(storage, written)
        if status == FINISHED then
            decoder:close()
            return table.concat(answer)
        end
        if status == NEED_INPUT then
            decoder:close()
            return nil, "truncated"
        end
    end
end

local function sample(count)
    local parts = {}
    local seed = 7
    for index = 1, count do
        seed = (seed * 1103515245 + 12345) % 2147483648
        -- Mostly a small alphabet, with runs, so matches of every length occur.
        if seed % 5 == 0 then
            parts[index] = string.rep(string.char(97 + seed % 7), seed % 40)
        else
            parts[index] = string.char(32 + seed % 90)
        end
    end

    return table.concat(parts)
end

function M.nativeProviderRoundTripsEveryFormatAcrossOneByteBoundaries()
    local provider = nativeProvider()
    assert(provider.formats.gzip.name == "gzip")
    assert(provider.formats.zlib.name == "zlib")
    assert(provider.formats["deflate-raw"].name == "deflate-raw")
    local input = "a bounded stream can cross any input and output boundary"
    for _, name in ipairs({"gzip", "zlib", "deflate-raw"}) do
        local compressed = encode(name, input, 1)
        assert(decode(name, compressed, 1) == input, name)
    end
end

function M.nativeProviderRoundTripsEveryLevelAndBlockShape()
    local inputs = {"", "x", string.rep("abc", 40000), sample(30000), sample(5000) .. string.rep("\0", 70000)}
    for _, name in ipairs({"gzip", "zlib", "deflate-raw"}) do
        for level = 0, 9 do
            for _, input in ipairs(inputs) do
                local compressed = encode(name, input, 4096, {level = level})
                local decoded, reason = decode(name, compressed, 3000)
                assert(decoded == input, ("%s level %d length %d: %s"):format(name, level, #input, tostring(reason)))
            end
        end
    end
    local repetitive = string.rep("compression-level", 1000)
    assert(#encode("gzip", repetitive, 65536, {level = 9}) < #encode("gzip", repetitive, 65536, {level = 0}))
end

function M.nativeProviderFlushFinishesWithAnyOutputRoom()
    for room = 1, 8 do
        local encoder = nativeProvider().formats.gzip:createencoder()
        local encoded = {}
        local storage, output = buffer(64)
        local consumed, written = encoder:write(view(bytesOf("hello"), 5), output)
        assert(consumed == 5)
        encoded[#encoded + 1] = ffi.string(storage, written)
        local calls = 0
        repeat
            calls = calls + 1
            assert(calls < 1000, "a flush with " .. room .. " bytes of room never finished")
            local small, smallView = buffer(room)
            local flushed, status = encoder:flush(smallView)
            encoded[#encoded + 1] = ffi.string(small, flushed)
        until status ~= NEED_OUTPUT
        -- Everything written so far decodes before the stream is finished.
        local partial = nativeProvider().formats.gzip:createdecoder()
        local joined = table.concat(encoded)
        local out, outView = buffer(64)
        local _, made = partial:read(view(bytesOf(joined), #joined), outView)
        assert(ffi.string(out, made) == "hello")
        partial:close()
        repeat
            local tail, tailView = buffer(64)
            local finished, status = encoder:finish(tailView)
            encoded[#encoded + 1] = ffi.string(tail, finished)
        until status == FINISHED
        assert(decode("gzip", table.concat(encoded), 7) == "hello")
    end
end

function M.nativeProviderDeliversStagedFlushBytesFirst()
    local encoder = nativeProvider().formats.zlib:createencoder()
    local encoded = {}
    local storage, output = buffer(64)
    local _, written = encoder:write(view(bytesOf("hello"), 5), output)
    encoded[#encoded + 1] = ffi.string(storage, written)
    local small, smallView = buffer(2)
    local flushed, status = encoder:flush(smallView)
    assert(status == NEED_OUTPUT)
    encoded[#encoded + 1] = ffi.string(small, flushed)
    repeat
        local consumed
        consumed, written, status = encoder:write(view(bytesOf("abc"), 3), output)
        encoded[#encoded + 1] = ffi.string(storage, written)
    until consumed == 3
    repeat
        written, status = encoder:finish(output)
        encoded[#encoded + 1] = ffi.string(storage, written)
    until status == FINISHED
    assert(decode("zlib", table.concat(encoded), 5) == "helloabc")
end

function M.nativeProviderValidatesMembersTrailersAndTruncation()
    local compressed = encode("gzip", "hello", 64)
    local decoded, reason = decode("gzip", compressed .. "\31", 64)
    assert(decoded == nil and reason:find("trailing bytes", 1, true), tostring(reason))

    decoded, reason = decode("gzip", compressed:sub(1, -2), 64)
    assert(decoded == nil and reason == "truncated", tostring(reason))

    local damaged = compressed:sub(1, -2) .. string.char(bit.bxor(compressed:byte(-1), 1))
    decoded, reason = decode("gzip", damaged, 64)
    assert(decoded == nil and reason:find("length check", 1, true), tostring(reason))
    damaged = compressed:sub(1, -9) .. string.char(bit.bxor(compressed:byte(-8), 1)) .. compressed:sub(-7)
    decoded, reason = decode("gzip", damaged, 64)
    assert(decoded == nil and reason:find("data check", 1, true), tostring(reason))

    local joined = encode("gzip", "hello", 2) .. encode("gzip", " world", 2)
    assert(decode("gzip", joined, 2) == "hello world")
    -- A single-member decoder finishes at the end of the first member and
    -- leaves the next one unread.
    local single = nativeProvider().formats.gzip:createdecoder({concatenatedmembers = false})
    local storage, output = buffer(64)
    local consumed, written, status = single:read(view(bytesOf(joined), #joined), output)
    assert(status == FINISHED and ffi.string(storage, written) == "hello")
    assert(consumed == #encode("gzip", "hello", 2), "the second member was consumed")
    single:close()
end

function M.nativeProviderDecodesIndependentStandardFixtures()
    local gzip = string.char(
        0x1f,
        0x8b,
        0x08,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x03,
        0xcb,
        0x48,
        0xcd,
        0xc9,
        0xc9,
        0x07,
        0x00,
        0x86,
        0xa6,
        0x10,
        0x36,
        0x05,
        0x00,
        0x00,
        0x00
    )
    local zlib = string.char(0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x06, 0x2c, 0x02, 0x15)
    local raw = string.char(0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00)
    assert(decode("gzip", gzip, 2) == "hello")
    assert(decode("zlib", zlib, 2) == "hello")
    assert(decode("deflate-raw", raw, 2) == "hello")
    local decoded, reason = decode("zlib", string.char(0x78, 0x9d) .. zlib:sub(3), 2)
    assert(decoded == nil and reason:find("header check", 1, true), tostring(reason))
end

function M.unavailableTargetsListNoCompressionWithoutLoadingTheBackend()
    local load = state.instance(
        {["bytes"] = true, ["nupp.compression"] = true},
        {["nupp.runtime.target"] = {dialect = "luajit", host = "browser"},},
        {
            ["nupp.runtime.provider.nativecompression"] = function()
                error("listing unavailable compression loaded its native backend")
            end,
        }
    )
    assert(#load("bytes").formats("compression") == 0)
end

return M
