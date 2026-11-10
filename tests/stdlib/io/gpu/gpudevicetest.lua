-- The native GPU device over wgpu-native: its range, handle and SPIR-V checks,
-- the cost output, and, where the machine has an adapter, real dispatches.
-- NUPP_REQUIRE_GPU turns a missing adapter from a skip into a failure, which is
-- how the GPU conformance jobs run it; NUPP_EXPECT_GPU_BACKEND and
-- NUPP_EXPECT_GPU_ADAPTER name the device those jobs must have found.
local ffi = require("ffi")
local assertions = require("assert")
local device = require("nupp.runtime.provider.gpudevice")
local costs = require("nupp.runtime.provider.gpucosts")
local json = require("serde.json")

local M = {}

local function fails(body, message)
    local ok, problem = pcall(body)
    assert(not ok, "expected a failure containing " .. message)
    local text = type(problem) == "table" and problem.message or tostring(problem)
    assert(text:find(message, 1, true), text)
end

local function temporary(name)
    local directory = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    return (directory:gsub("\\", "/")) .. "/nupp-gpu-" .. name .. "-" .. tostring(os.time()) .. "-"
        .. tostring(math.random(1, 1000000)) .. ".jsonl"
end

local function lines(path)
    local rows = {}
    local file = assert(io.open(path, "rb"))
    for line in file:lines() do
        rows[#rows + 1] = line
    end
    file:close()
    return rows
end

-- A device, or a skip when the machine has none and none is required.
local function open()
    local context, problem = device.open()
    if context == nil then
        assert(os.getenv("NUPP_REQUIRE_GPU") == nil, "required GPU adapter is unavailable: " .. tostring(problem))
        assertions.suite.skip("no GPU adapter: " .. tostring(problem))
    end
    return context
end

local ROUND_TRIP = [[
@group(1) @binding(0)
var<storage, read_write> values: array<u32>;

@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    values[id.x] = values[id.x] + 1u;
}
]]

local NO_UNIFORMS = ffi.new("uint8_t[1]")

local function check(value, problem)
    assert(problem == nil, problem)
    return value
end

function M.invalidTimestampIntervalsDoNotClaimDeviceDuration()
    local first, last = ffi.new("uint64_t", 10), ffi.new("uint64_t", 1010)
    assert(device.timestampmilliseconds(first, last, 2.0) == 0.002)
    local _, equal = device.timestampmilliseconds(ffi.new("uint64_t", 0), ffi.new("uint64_t", 0), 1.0)
    assert(equal == "equal-timestamps")
    local _, reversed = device.timestampmilliseconds(ffi.new("uint64_t", 10), ffi.new("uint64_t", 9), 1.0)
    assert(reversed == "reversed-timestamps")
    for _, period in ipairs({0.0, -1.0, 0 / 0, math.huge}) do
        local _, reason = device.timestampmilliseconds(ffi.new("uint64_t", 10), ffi.new("uint64_t", 20), period)
        assert(reason == "invalid-timestamp-period", tostring(period))
    end
end

function M.resourceTablesRejectWrongAndStaleHandles()
    local table = device.resources()
    local buffer = device.insert(table, "buffer", 11)
    fails(function() device.remove(table, buffer, "kernel") end, "is a buffer, not a kernel")
    assert(device.remove(table, buffer, "buffer") == 11)
    fails(function() device.remove(table, buffer, "buffer") end, "unknown or released GPU handle " .. buffer)
end

function M.publicHandlesDoNotCrossContexts()
    local left, right = device.resources(), device.resources()
    local handle = device.insert(left, "buffer", true)
    fails(function() device.lookup(right, handle, "buffer") end, "unknown or released GPU handle")
    assert(handle ~= device.insert(right, "buffer", true))
end

function M.rangeChecksRejectOverflowAndOverrun()
    device.checkedrange("test", 4, 4, 8)
    fails(function() device.checkedrange("test", 5, 4, 8) end, "test range 5..9 exceeds buffer size 8")
    fails(function() device.checkedrange("test", 2 ^ 53, 2, 2 ^ 53) end, "exceeds buffer size")
end

function M.aRangeThatEndsTheBufferMayEndPartwayThroughAWord()
    assert(device.copyextent("upload", 0, 8, 8) == 8)
    assert(device.copyextent("upload", 0, 3, 3) == 4)
    assert(device.copyextent("upload", 4, 3, 7) == 4)
    fails(function() device.copyextent("upload", 0, 3, 8) end, "does not end the buffer")
    fails(function() device.copyextent("upload", 2, 2, 4) end, "offset 2 is not aligned")
end

function M.oneAllocationIsNotBoundForReadingAndWriting()
    local slot = {buffer = 7, offset = 0, size = 4}
    assert(device.binds({false, slot}, 7))
    assert(not device.binds({false, slot}, 8))
    assert(not device.binds({false, false}, 7))
end

local function words(values)
    local bytes = {}
    for _, value in ipairs(values) do
        bytes[#bytes + 1] = string.char(value % 256, math.floor(value / 256) % 256,
            math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
    end
    return table.concat(bytes)
end

local function moduleWithLocalSize(x, y, z)
    -- OpEntryPoint GLCompute %4 "main"; OpExecutionMode %4 LocalSize x y z
    return {
        0x07230203, 0x00010300, 0, 20, 0,
        5 * 65536 + 15, 5, 4, 0x6e69616d, 0,
        6 * 65536 + 16, 4, 17, x, y, z,
    }
end

function M.spirvIngestionIsBoundedAndEndianChecked()
    fails(function() device.spirvwords("") end, "complete 32-bit words")
    fails(function() device.spirvwords("\3\2\35") end, "complete 32-bit words")
    fails(function() device.spirvwords("\7\35\2\3") end, "invalid magic word or byte order")
    local spirv, count = device.spirvwords("\3\2\35\7")
    assert(count == 1 and spirv[0] == 0x07230203)
end

function M.aDeclaredWorkgroupSizeMustBeTheCompiledOne()
    local module = moduleWithLocalSize(64, 1, 1)
    local spirv, count = device.spirvwords(words(module))
    device.checkworkgroupsize(spirv, count, "main", {64, 1, 1})
    fails(function() device.checkworkgroupsize(spirv, count, "main", {128, 1, 1}) end,
        "declares workgroup size [128, 1, 1], but main is compiled for [64, 1, 1]")
    device.checkworkgroupsize(spirv, count, "other", {128, 1, 1})
    local truncated, short = device.spirvwords(words({unpack(module, 1, #module - 1)}))
    fails(function() device.checkworkgroupsize(truncated, short, "main", {64, 1, 1}) end, "invalid length")
end

function M.closingAfterAWriteErrorPreservesTheErrorAndResetsTheSink()
    local path = temporary("close")
    assert(costs.configure(path) == nil)
    costs.injectfailure("injected write failure")
    costs.setsequence(7)
    assert(costs.configure(nil) == "injected write failure")
    local state = costs.state()
    assert(not state.open, "failed close retained the output file")
    assert(state.failure == nil and not state.initialized and not state.active and not state.configured)
    assert(state.sequence == 7, "the sequence runs on across destinations")
    os.remove(path)
end

function M.aFailedOutputStillGivesWayToTheNextOne()
    local path = temporary("next")
    costs.injectfailure("injected write failure")
    assert(costs.configure(path) == "injected write failure")
    assert(io.open(path, "rb"), "the new destination was not opened"):close()
    assert(costs.enabled())
    assert(costs.configure(nil) == nil)
    os.remove(path)
end

function M.recordsAreJsonAndKeepHostAndGpuTimesDistinct()
    local line = costs.encode(7, "kernel", {sourceFile = "a\"b\\c.nupp", hostMs = 1.0, gpuMs = costs.NULL,
        gpuTiming = "unavailable"}, 1)
    local row = assert(json.decodevalue(line:gsub("\n$", ""), json.NULL))
    assert(row.sourceFile == "a\"b\\c.nupp")
    assert(row.gpuMs == json.NULL)
    assert(row.hostMs == 1.0 and row.sequence == 1 and row.context == 7 and row.target == "gpu")
    assert(line:find('"gpuMs":null', 1, true), line)
end

function M.narrowBuffersMoveBytesThatEndPartwayThroughAWordWhenAvailable()
    local gpu = open()
    local buffer = check(device.createbuffer(gpu, 3))
    check(device.upload(gpu, buffer, 0, ffi.new("uint8_t[3]", {1, 2, 3}), 3))
    check(device.queuedownload(gpu, buffer, 0, 3))
    check(device.synchronize(gpu))
    local bytes = ffi.new("uint8_t[3]")
    check(device.readdownload(gpu, buffer, 0, 3, bytes))
    assert(bytes[0] == 1 and bytes[1] == 2 and bytes[2] == 3)
    local kernel = check(device.createwgslkernel(gpu, ROUND_TRIP, {1, 1, 1}))
    local bindings = check(device.createbindings(gpu, kernel))
    check(device.setbuffer(gpu, bindings, true, 0, buffer, 0, 3))
    check(device.releasebindings(gpu, bindings))
    check(device.releasekernel(gpu, kernel))
    check(device.releasebuffer(gpu, buffer))
    check(device.close(gpu))
end

function M.anUnreadDownloadSaysSoWhenAvailable()
    local gpu = open()
    local buffer = check(device.createbuffer(gpu, 16))
    check(device.queuedownload(gpu, buffer, 0, 16))
    local _, pending = device.queuedownload(gpu, buffer, 0, 16)
    assert(pending == "gpu: buffer " .. buffer .. " already has a queued download", pending)
    local _, held = device.releasebuffer(gpu, buffer)
    assert(held == pending, held)
    check(device.synchronize(gpu))
    local _, unread = device.queuedownload(gpu, buffer, 0, 16)
    assert(unread == "gpu: buffer " .. buffer .. " has a synchronized download that has not been read yet", unread)
    local _, mismatch = device.readdownload(gpu, buffer, 4, 12, ffi.new("uint8_t[12]"))
    assert(mismatch == "gpu: downloaded range 0..16 does not match requested range 4..16", mismatch)
    check(device.readdownload(gpu, buffer, 0, 16, ffi.new("uint8_t[16]")))
    local _, missing = device.readdownload(gpu, buffer, 0, 16, ffi.new("uint8_t[16]"))
    assert(missing == "gpu: buffer " .. buffer .. " has no synchronized download", missing)
    check(device.queuedownload(gpu, buffer, 0, 16))
    check(device.synchronize(gpu))
    check(device.releasebuffer(gpu, buffer))
    check(device.close(gpu))
end

function M.aCostOutputFailureLeavesAConsumedDownloadReadWhenAvailable()
    local gpu = open()
    local buffer = check(device.createbuffer(gpu, 16))
    check(device.upload(gpu, buffer, 0, ffi.new("uint8_t[16]", {9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}), 16))
    check(device.queuedownload(gpu, buffer, 0, 16))
    check(device.synchronize(gpu))
    costs.injectfailure("injected write failure")
    local bytes = ffi.new("uint8_t[16]")
    check(device.readdownload(gpu, buffer, 0, 16, bytes))
    assert(bytes[0] == 9 and bytes[15] == 9)
    assert(costs.check() == "injected write failure")
    check(device.releasebuffer(gpu, buffer))
    check(device.close(gpu))
end

function M.submittedWorkIsAnsweredWithoutBlockingWhenAvailable()
    local gpu = open()
    local kernel = check(device.createwgslkernel(gpu, ROUND_TRIP, {1, 1, 1}))
    local buffer = check(device.createbuffer(gpu, 65536))
    local bindings = check(device.createbindings(gpu, kernel))
    check(device.setbuffer(gpu, bindings, true, 0, buffer, 0, 65536))
    for _ = 1, 8 do
        check(device.dispatch(gpu, bindings, {16384, 1, 1}, NO_UNIFORMS, 0))
    end
    local deadline = os.time() + 30
    while not check(device.workdone(gpu)) do
        assert(os.time() < deadline, "GPU work never finished")
        device.pause(1)
    end
    assert(check(device.workdone(gpu)))
    check(device.synchronize(gpu))
    check(device.close(gpu))
end

function M.invalidSpirvIsAValidationFailureWhenAvailable()
    local gpu = open()
    local module = moduleWithLocalSize(64, 1, 1)
    local _, problem = device.createkernel(gpu, words(module), "main", 0, 1, 0, {64, 1, 1})
    assert(problem and problem:find("^gpu: GPU validation: "), tostring(problem))
    local buffer = check(device.createbuffer(gpu, 16))
    check(device.releasebuffer(gpu, buffer))
    check(device.close(gpu))
end

function M.adapterComputeRoundTripWhenAvailable()
    local path = temporary("integration")
    assert(costs.configure(path) == nil)
    local gpu, problem = device.open()
    if gpu == nil then
        assert(costs.configure(nil) == nil)
        os.remove(path)
        assert(os.getenv("NUPP_REQUIRE_GPU") == nil, "required GPU adapter is unavailable: " .. tostring(problem))
        assertions.suite.skip("no GPU adapter: " .. tostring(problem))
    end
    local description = device.description(gpu)
    local backend, adapter = os.getenv("NUPP_EXPECT_GPU_BACKEND"), os.getenv("NUPP_EXPECT_GPU_ADAPTER")
    assert(backend == nil or description:find("^" .. backend .. ": "), description)
    assert(adapter == nil or description:lower():find(adapter:lower(), 1, true), description)
    local contextId = device.costid(gpu)
    local timestamps = device.timestamps(gpu)
    local kernel = check(device.createwgslkernel(gpu, ROUND_TRIP, {1, 1, 1}))
    check(device.metadata(gpu, kernel, true, {sourceFile = "round-trip.nupp", sourceLine = 8,
        artifactId = "fixture", writableNames = {"values"}}))
    local buffer = check(device.createbuffer(gpu, 16))
    check(device.metadata(gpu, buffer, false, {format = "uint32", shape = {4}, elementBytes = 4}))
    check(device.upload(gpu, buffer, 0, ffi.new("uint32_t[4]", {1, 2, 3, 4}), 16))
    local bindings = check(device.createbindings(gpu, kernel))
    check(device.setbuffer(gpu, bindings, true, 0, buffer, 0, 16))
    check(device.metadata(gpu, buffer, false, {shape = {2, 2}, strides = {2, 1}}))
    check(device.dispatch(gpu, bindings, {4, 1, 1}, NO_UNIFORMS, 0))
    check(device.dispatch(gpu, bindings, {4, 1, 1}, NO_UNIFORMS, 0))
    check(device.queuedownload(gpu, buffer, 0, 16))
    -- This upload is ordered after the queued copy; its version must not
    -- replace the downloaded snapshot's provenance.
    check(device.metadata(gpu, buffer, false, {shape = {1, 4}, strides = {4, 1}}))
    check(device.upload(gpu, buffer, 0, ffi.new("uint32_t[4]"), 16))
    check(device.synchronize(gpu))
    local values = ffi.new("uint32_t[4]")
    check(device.readdownload(gpu, buffer, 0, 16, values))
    assert(values[0] == 3 and values[1] == 4 and values[2] == 5 and values[3] == 6)
    -- Hardware without timestamp support, even on an adapter that has it: no
    -- host duration may masquerade as device time.
    device.timestamps(gpu, false)
    check(device.dispatch(gpu, bindings, {4, 1, 1}, NO_UNIFORMS, 0))
    check(device.synchronize(gpu))
    assert(costs.configure(nil) == nil)
    -- A retained device keeps its capability, but disabling costs must stop
    -- allocating and resolving queries on later dispatches.
    device.timestamps(gpu, timestamps)
    check(device.dispatch(gpu, bindings, {4, 1, 1}, NO_UNIFORMS, 0))
    assert(device.pendingtimestamps(gpu) == 0)
    check(device.synchronize(gpu))
    local rows = {}
    for _, line in ipairs(lines(path)) do
        local row = assert(json.decodevalue(line, json.NULL))
        if row.context == contextId then
            rows[#rows + 1] = row
        end
    end
    local function find(operation)
        for _, row in ipairs(rows) do
            if row.operation == operation then
                return row
            end
        end
    end
    assert(find("adapterDevice"))
    local dispatches = {}
    for _, row in ipairs(rows) do
        if row.operation == "dispatch" then
            dispatches[#dispatches + 1] = row
        end
    end
    assert(#dispatches == 3, #dispatches)
    assert(dispatches[3].gpuTiming == "unavailable" and dispatches[3].gpuMs == json.NULL)
    assert(dispatches[1].phase == "first-use" and dispatches[2].phase == "steady-state")
    assert(dispatches[1].bindingsReused == false)
    assert(dispatches[2].bindingsReused == true, "absent layouts do not count as cache misses")
    assert(dispatches[2].write[1].version == 3)
    assert(dispatches[1].write[1].layout.shape[1] == 4 and #dispatches[1].write[1].layout.shape == 1,
        "bindings retain their own view shape")
    assert(dispatches[1].metadata.writableNames[1] == "values")
    for _, operation in ipairs({"downloadQueue", "downloadMapCopy", "downloadHostCopy"}) do
        local row = assert(find(operation), operation)
        assert(row.version == 3, operation .. " keeps the queued snapshot version")
        assert(row.bytes == 16)
        assert(row.layout.shape[1] == 2 and row.layout.shape[2] == 2, operation .. " keeps queued layout")
    end
    if timestamps then
        local timings = {}
        for _, row in ipairs(rows) do
            if row.operation == "kernelExecution" then
                timings[#timings + 1] = row
            end
        end
        assert(#timings == 2, #timings)
        for _, timing in ipairs(timings) do
            local first = ffi.new("uint64_t", tonumber(timing.gpuTicksBegin))
            local last = ffi.new("uint64_t", tonumber(timing.gpuTicksEnd))
            local _, reason = device.timestampmilliseconds(first, last, timing.gpuTickPeriodNs)
            if reason == nil then
                assert(timing.gpuTiming == "timestamp-query" and type(timing.gpuMs) == "number")
                assert(timing.gpuTimingReason == json.NULL)
            else
                assert(timing.gpuTiming == "unavailable" and timing.gpuMs == json.NULL)
                assert(timing.gpuTimingReason == reason)
            end
        end
    else
        assert(dispatches[1].gpuTiming == "unavailable")
    end
    os.remove(path)
    check(device.releasebindings(gpu, bindings))
    check(device.releasekernel(gpu, kernel))
    check(device.releasebuffer(gpu, buffer))
    local _, stale = device.releasebuffer(gpu, buffer)
    assert(stale == "gpu: unknown or released GPU handle " .. buffer, stale)
    check(device.close(gpu))
end

return M
