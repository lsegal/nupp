-- The readiness generation and wake handle `nupp.runtime.native` keeps for each
-- Lua state, which the network, process and HTTP families sleep on. It is Nupp
-- over the operating system's own event and pipe calls, so none of it reaches
-- the Rust provider.
local test = require("assert")
local ffi = require("ffi")
local native = require("nupp.runtime.native")

local HERE = require("helpers.paths").tests
local ROOT = HERE .. "/.."

local M = {}

local windows = ffi.os == "Windows"

if windows then
    pcall(
        ffi.cdef,
        [[
    uint32_t nupp_readiness_test_wait(void *, uint32_t) __asm__("WaitForSingleObject");
    int32_t nupp_readiness_test_reset(void *) __asm__("ResetEvent");
    ]]
    )
else
    pcall(ffi.cdef, [[
    intptr_t nupp_readiness_test_read(int, void *, size_t) __asm__("read");
    ]])
end

-- Whether the wake handle was signalled, resetting it as a family does.
local function signalled(handle)
    if windows then
        local event = ffi.cast("void *", handle)
        local set = ffi.C.nupp_readiness_test_wait(event, 0) == 0
        ffi.C.nupp_readiness_test_reset(event)
        return set
    end
    local scratch = ffi.new("uint8_t[64]")
    local set = false
    while tonumber(ffi.C.nupp_readiness_test_read(tonumber(handle), scratch, 64)) > 0 do
        set = true
    end
    return set
end

-- Leaves no snapshot behind for the next case, or the next suite in this state.
local function clear()
    native.snapshot()
    native.settle()
end

function M.afterEach()
    clear()
end

function M.anAdvanceAfterTheSnapshotEndsTheSleepAtOnce()
    clear()
    native.snapshot()
    native.advance()
    local started = os.time()
    test.eq(native.sleep(5000), 0)
    assert(os.time() - started < 3, "the sleep waited out its timeout after an advance")
end

function M.settleAnswersWhetherTheGenerationHeldSinceTheSnapshot()
    clear()
    native.snapshot()
    test.eq(native.settle(), true, "nothing moved")
    native.snapshot()
    native.advance()
    test.eq(native.settle(), false, "an advance after the snapshot")
end

function M.withoutASnapshotSleepAndSettleTakeOneAndReturnAtOnce()
    clear()
    test.eq(native.settle(), false, "a settle with no snapshot")
    test.eq(native.settle(), true, "the snapshot the first settle took")
    local started = os.time()
    test.eq(native.sleep(5000), 0)
    assert(os.time() - started < 3, "a sleep with no snapshot slept")
    test.eq(native.settle(), true, "the snapshot the sleep took")
end

function M.oneSnapshotServesThePassUntilTheNextSleep()
    clear()
    native.snapshot()
    native.advance()
    -- A second family's check in the same pass keeps the first snapshot, so the
    -- advance between them still wakes the sleep.
    native.snapshot()
    test.eq(native.settle(), false, "the pass's first snapshot was kept")
end

function M.aZeroTimeoutNeverSleeps()
    clear()
    native.snapshot()
    local started = os.time()
    test.eq(native.sleep(0), 0)
    assert(os.time() - started < 2, "a zero timeout slept")
end

function M.anAdvanceSignalsTheStatesOneWakeHandle()
    local handle = native.wake()
    assert(handle ~= nil, "the system opened no wake handle")
    assert(native.wake() == handle, "the state opened a second wake handle")
    signalled(handle)
    assert(not signalled(handle), "a reset handle is still signalled")
    native.advance()
    assert(signalled(handle), "an advance did not signal the wake handle")
    assert(not signalled(handle), "the reset did not clear the wake handle")
    native.advance()
    native.advance()
    assert(signalled(handle), "repeated advances did not signal the wake handle")
end

function M.theFamiliesThatSleepOnReadinessNeedNoRustProvider()
    for _, name in ipairs({"nativenet", "nativeprocess", "nativehttp"}) do
        local file = assert(io.open(ROOT .. "/src/nupp/runtime/provider/" .. name .. ".nupp", "rb"))
        local source = file:read("*a")
        file:close()
        assert(not source:find("native.C", 1, true), name .. " calls into the Rust provider")
        assert(not source:find("nuppNative", 1, true), name .. " names a Rust provider export")
    end
    local file = assert(io.open(ROOT .. "/src/nupp/runtime/native.nupp", "rb"))
    local source = file:read("*a")
    file:close()
    assert(not source:find("nuppNativePoll", 1, true), "readiness still polls the Rust provider")
    assert(not source:find("nuppNativeWake", 1, true), "readiness still opens the Rust provider's wake handle")
end

return M
