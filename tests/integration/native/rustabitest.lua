local HERE = require("helpers.paths").tests
local ROOT = HERE .. "/.."
local test = require("assert")

local M = {}

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read(path)
    local file = assert(io.open(path, "rb"), "cannot read " .. path)
    local text = file:read("*a")
    file:close()
    return text
end

local function run(command)
    local pipe = assert(io.popen(command .. " 2>&1; echo __exit__:$?"))
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__exit__:(%d+)%s*$"))
    return status, (output:gsub("__exit__:%d+%s*$", ""))
end

local function temporary()
    local path = os.tmpname()
    os.remove(path)
    assert(os.execute("mkdir -p " .. quote(path)) == 0)
    return path
end

local DEFINITION = ROOT .. "/native/abi/nuppnative.nupp"

--- The header `scripts/native-abi-header` generates from the definition.
local function header()
    local directory = temporary()
    local path = directory .. "/nupp_native.h"
    local status, output = run(("%s/scripts/native-abi-header %s"):format(quote(ROOT), quote(path)))
    assert(status == 0, output)
    return path, read(path)
end

--- What a C compiler makes of the header: it compiles on its own, warnings as
--- errors, as C11 and as C++.
function M.theGeneratedHeaderCompiles()
    local path = header()
    local cc = os.getenv("NUPP_CC") or os.getenv("CC") or "cc"
    local source = path:gsub("%.h$", ".c")
    local file = assert(io.open(source, "wb"))
    file:write('#include "nupp_native.h"\nint main(void) { return NUPP_NATIVE_OK; }\n')
    file:close()
    local status, output = run(("%s -std=c11 -Wall -Wextra -Werror -fsyntax-only %s"):format(cc, quote(source)))
    assert(status == 0, output)
end

--- The provider a C consumer would link, `native-rust` with URIs, called
--- through the declarations the generated header makes: everything the
--- header promises about it holds.
function M.theGeneratedHeaderDescribesTheProvider()
    local _, text = header()
    local status, provider = run(("cd %s && ./scripts/toolchain native-rust base,uri"):format(quote(ROOT)))
    assert(status == 0, provider)
    provider = provider:match("([^\r\n]+)%s*$")

    -- The declarations, with the preprocessor's lines and the layout checks left
    -- to the compiler test above.
    local declarations, defines = {}, {}
    for line in text:gmatch("[^\n]+") do
        local name, value = line:match("^#define (NUPP_NATIVE_[%u%d_]+) (%d+)U?L?L?$")
        if name ~= nil then
            defines[name] = tonumber(value)
        elseif not line:match("^%s*#") and not line:match("_STATIC_ASSERT") and line ~= "extern \"C\" {" and line ~= "}" then
            declarations[#declarations + 1] = line
        end
    end
    local ffi = require("ffi")
    ffi.cdef(table.concat(declarations, "\n"))
    local native = ffi.load(provider)

    test.eq(native.nuppNativeAbiVersion(), defines.NUPP_NATIVE_ABI_VERSION, "the ABI version")
    local features = native.nuppNativeFeatures()
    local wanted = defines.NUPP_NATIVE_FEATURE_BASE + defines.NUPP_NATIVE_FEATURE_URI
    test.eq(tonumber(require("bit").band(features, wanted)), wanted, "the requested feature bits")
    assert(defines.NUPP_NATIVE_FEATURE_READINESS == nil, "readiness is Nupp's, not the provider's")
    for _, name in ipairs({"nuppNativePoll", "nuppNativeWait", "nuppNativeWakeOpen", "nuppNativeWakeClose"}) do
        assert(not text:find(name .. "(", 1, true), name .. " outlived the stage zero that needed it")
    end

    local uri = ffi.new("uint64_t[1]")
    local spelling = "https://EXAMPLE.com"
    test.eq(native.nuppNativeUriParse(spelling, #spelling, uri), defines.NUPP_NATIVE_OK, "URI parse")
    local length = ffi.new("uint64_t[1]")
    local present = ffi.new("int32_t[1]")
    test.eq(
        native.nuppNativeUriPart(uri[0], defines.NUPP_NATIVE_URI_HOST, nil, 0, length, present),
        defines.NUPP_NATIVE_BUFFER_TOO_SMALL,
        "a URI part size query"
    )
    test.eq(tonumber(length[0]), #"example.com", "the size a query answers")
    local small = ffi.new("uint8_t[2]")
    test.eq(
        native.nuppNativeUriPart(uri[0], defines.NUPP_NATIVE_URI_HOST, small, 2, length, present),
        defines.NUPP_NATIVE_BUFFER_TOO_SMALL,
        "a short URI part output"
    )
    assert(present[0] ~= 0, "the host is present")
    test.eq(native.nuppNativeUriRelease(uri[0]), defines.NUPP_NATIVE_OK, "URI release")
    test.eq(native.nuppNativeUriRelease(uri[0]), defines.NUPP_NATIVE_STALE_HANDLE, "a released URI handle")
end

-- Symbols the pinned bundle names that were deleted before this check existed.
-- Each is declared in a cdef the bundle never reaches, which is the only reason
-- its deletion was harmless; nothing may join this list.
local REMOVED_BEFORE_THE_CHECK = {nuppNativeProcessAbandonedTotal = true,}

-- The pinned stage-zero compiler loads this checkout's freshly built provider,
-- so the provider may only grow. The ABI version stays the one the bundle
-- checks for exactly, and every provider symbol the bundle names is still
-- declared: a deleted one breaks a cold build the moment the bundle reaches it,
-- and nothing but the bundle's own text says whether it can.
function M.theProviderKeepsWhatThePinnedStageZeroNames()
    local pipe = assert(io.popen(("cd %s && ./scripts/toolchain stage0 2>/dev/null"):format(quote(ROOT))))
    local path = pipe:read("*a"):match("([^\r\n]+)%s*$")
    pipe:close()
    assert(path, "no stage-zero compiler; run scripts/toolchain stage0")
    local bundle = read(assert(path:match("^(.*)[/\\][^/\\]+$")) .. "/verified.lua")
    local definition = read(DEFINITION)

    local required = assert(bundle:match("\nconst ABI_VERSION = (%d+)\n"), "the bundle checks no ABI version")
    local provided = assert(
        definition:match("\nexport const NUPP_NATIVE_ABI_VERSION = (%d+)\n"),
        "the definition has no ABI version"
    )
    assert(
        required == provided,
        ("the pinned stage zero needs ABI %s and the definition says %s"):format(required, provided)
    )

    local declared = {}
    for name in definition:gmatch("\ncdef function ([%w_]+)%(") do
        declared[name] = true
    end
    local missing, seen = {}, {}
    for name in bundle:gmatch("[%w_]+") do
        if name:match("^nuppNative") and not seen[name] then
            seen[name] = true
            if not declared[name] and not REMOVED_BEFORE_THE_CHECK[name] then
                missing[#missing + 1] = name
            end
        end
    end
    table.sort(missing)
    assert(next(seen), "the bundle names no provider symbol, so this check reads the wrong text")
    assert(
        #missing == 0,
        "the pinned stage zero names provider symbols the definition lost: " .. table.concat(missing, ", ")
    )
end

return M
