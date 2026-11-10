-- `nupp aot --emit executable`: a native program whose `main` is written in Nupp.
--
-- Driven through the real binary, and the program it links is run, because the
-- executable and its exit status are the interface.

local test = require("assert")

local HERE = require("helpers.paths").absoluteTests
local NUPP = HERE .. "/../bin/nupp"

local M = {}

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

local function project(source)
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p " .. quote(dir)) == 0)
    local manifest = assert(io.open(dir .. "/nupp.lua", "wb"))
    manifest:write('return {include = {"."}}\n')
    manifest:close()
    local handle = assert(io.open(dir .. "/host.nupp", "wb"))
    handle:write(source)
    handle:close()

    return dir
end

local function executableName(dir)
    return dir .. "/host" .. (jit.os == "Windows" and ".exe" or "")
end

--- Links `source` as a native program, or returns nil and what `nupp` said.
local function link(source)
    local dir = project(source)
    local executable = executableName(dir)
    local status, output = run(
        ("cd %s && NO_COLOR= %s aot --emit executable --output %s host.nupp"):format(
            quote(dir),
            quote(NUPP),
            quote(executable)
        )
    )
    if status ~= 0 then
        return nil, output
    end

    return executable, output
end

local function requireCodegen()
    local available, why = require("nupp.tools.build.aotllvm").selected()
    if available ~= true then
        test.suite.skip("this nupp has no code generator: " .. tostring(why))
    end
end

local LUA_API = [[
cdef function luaL_newstate(): voidptr
cdef function luaL_openlibs(borrows L: voidptr)
cdef function luaL_loadstring(borrows L: voidptr, source: cstring): int32
cdef function lua_pcall(borrows L: voidptr, nargs: int32, nresults: int32, handler: int32): int32
cdef function lua_pushcclosure(borrows L: voidptr, fn: function(L: voidptr): int32, n: int32)
cdef function lua_pushnumber(borrows L: voidptr, n: number)
cdef function lua_pushstring(borrows L: voidptr, s: cstring)
cdef function lua_setfield(borrows L: voidptr, index: int32, k: cstring)
cdef function lua_tonumber(borrows L: voidptr, index: int32): number
cdef function lua_tolstring(borrows L: voidptr, index: int32, length: voidptr?): cstring
cdef function lua_close(borrows L: voidptr)
cdef function puts(borrows s: cstring): int32

const GLOBALS = -10002
]]

-- `main` creates a LuaJIT state, registers a Nupp function as a C callback,
-- runs a chunk under `lua_pcall`, and exits with what the chunk returned.
local HOST = LUA_API .. [[

local function answer(L: voidptr): int32
    lua_pushnumber(L, 42)
    return 1
end

--- The sum of 1..n with every multiple of 3 skipped, by loop and branch.
local function tally(n: int32): number
    local total = 0
    for i = 1, n do
        if i % 3 ~= 0 then
            total += i
        end
    end
    return total
end

local function main(argc: int32, argv: cstring*): int32
    local L = luaL_newstate()
    luaL_openlibs(L)
    lua_pushcclosure(L, answer, 0)
    lua_setfield(L, GLOBALS, "answer")
    lua_pushnumber(L, tally(10))
    lua_setfield(L, GLOBALS, "tally")
    if argc > 1 then
        @unsafe do
            lua_pushstring(L, argv[1])
        end
        lua_setfield(L, GLOBALS, "name")
    end
    local chunk = "print('hello ' .. tostring(name) .. ' ' .. answer() .. ' ' .. tally) return answer() - 40"
    if luaL_loadstring(L, chunk) ~= 0 then
        return 100
    end
    local status = lua_pcall(L, 0, 1, 0)
    if status ~= 0 then
        puts(lua_tolstring(L, -1, nil))
        lua_close(L)
        return math.i32.wrap(100 + status)
    end
    local result = math.i32.wrap(math.floor(lua_tonumber(L, -1)))
    lua_close(L)
    return result
end
]]

function M.mainRunsALuaChunkAndExitsWithItsStatus()
    requireCodegen()
    local executable, output = link(HOST)
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable) .. " world")
    test.eq(status, 2, ran)
    test.eq(ran, "hello world 42 37")
end

-- A Lua error raised inside a Nupp callback unwinds through its native frame
-- to the VM's protected call, which needs the frame's unwind tables.
function M.aNuppCallbackRaisingAnErrorReachesProtectedCall()
    requireCodegen()
    local executable, output = link(LUA_API .. [[
cdef function luaL_error(borrows L: voidptr, format: cstring, ...): int32

local function fail(L: voidptr): int32
    return luaL_error(L, "failed with %g", 7)
end

local function main(): int32
    local L = luaL_newstate()
    luaL_openlibs(L)
    lua_pushcclosure(L, fail, 0)
    lua_setfield(L, GLOBALS, "fail")
    if luaL_loadstring(L, "fail()") ~= 0 then
        return 100
    end
    local status = lua_pcall(L, 0, 0, 0)
    puts(lua_tolstring(L, -1, nil))
    lua_close(L)
    return status
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 2, ran)
    assert(ran:find("failed with 7", 1, true), ran)
end

-- `integer` and `number` are binary64, so `//` and `%` floor and `/` divides
-- exactly; `int64` wraps; refinements enter through the establishing calls.
function M.arithmeticKeepsTheLanguagesMeaning()
    requireCodegen()
    local executable, output = link([[
local function check(ok: boolean, code: integer): integer
    if ok then
        return 0
    end
    return code
end

local function main(): int32
    local a = -7
    local b = 2
    local failed = check(a // b == -4, 1) + check(a % b == 1, 2) + check(a / b == -3.5, 3)
    local wide: int64 = 9223372036854775807LL
    failed += check(wide + 1LL == -9223372036854775807LL - 1LL, 4)
    local x = 7.5
    failed += check(x // 2 == 3, 5) + check(x % 2 == 1.5, 6)
    local narrow: int32 = math.i32.wrap(4294967297)
    failed += check(narrow == 1, 7)
    local count = 0
    while true do
        count += 1
        if count >= 5 then
            break
        end
    end
    failed += check(count == 5 and math.floor(-0.5) == -1 and math.sqrt(16) == 4, 8)
    return math.i32.wrap(failed)
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ran)
end

local ffi = require("ffi")

-- The structs the field cases declare, as LuaJIT lays them out.
ffi.cdef([[
typedef struct {
    int8_t tag;
    float weight;
} nuppNativeProgramInner;

typedef struct {
    bool flag;
    int8_t small;
    uint16_t count;
    int32_t index;
    uint32_t id;
    int64_t big;
    double value;
    nuppNativeProgramInner inner;
    void *next;
} nuppNativeProgramNode;
]])

local STRUCTS = [[
cdef function calloc(count: uint64, size: uint64): voidptr
cdef function free(borrows p: voidptr)
cdef function printf(borrows format: cstring, ...): int32

cdef struct Inner
    tag: int8
    weight: float
end

cdef struct Node
    flag: boolean
    small: int8
    count: uint16
    index: integer
    id: uint32
    big: int64
    value: number
    inner: Inner
    next: Node*?
end
]]

--- `n`'s fields and the bytes of `count` structs from it, as the native
--- program below prints them.
local function describe(n, count)
    local big = tostring(n[0].big):gsub("LL$", "")
    local fields = ("%d %g %g %g %g %s %g %g %.17g %d %g %g\n"):format(
        n[0].flag and 1 or 0,
        n[0].small,
        n[0].count,
        n[0].index,
        n[0].id,
        big,
        n[0].value,
        n[0].inner.tag,
        n[0].inner.weight,
        n[1].flag and 1 or 0,
        n[1].id,
        n[1].inner.tag
    )
    local bytes = ffi.cast("uint8_t *", n)
    local listed = {}
    for i = 0, count * ffi.sizeof("nuppNativeProgramNode") - 1 do
        listed[#listed + 1] = ("%g "):format(bytes[i])
    end

    return fields .. table.concat(listed) .. "\n"
end

-- Each field read and write through a `cdef struct` pointer, nested structs and
-- `p[i]` of a struct included, gives what the same code gives under LuaJIT: the
-- same values read back, and the same bytes in memory, padding included.
function M.cdefStructFieldsReadAndWriteAsUnderLuaJIT()
    requireCodegen()
    local size = ffi.sizeof("nuppNativeProgramNode")
    local executable, output = link(STRUCTS .. ([[

const SIZE = %d

local function main(): int32
    local nodes = calloc(2, SIZE) as Node*
    local other = calloc(1, SIZE) as Node*
    @unsafe do
        nodes.flag = true
        nodes.small = -5
        nodes.count = 65535
        nodes.count += 2
        nodes.index = -7
        nodes.index *= 3
        nodes.id = 4000000000
        nodes.big = 9223372036854775807LL
        nodes.big += 1LL
        nodes.value = 2.5
        nodes.value *= 3
        nodes.inner.tag = -9
        nodes.inner.weight = 0.1
        nodes[1].id = nodes.id + 1
        nodes[1].inner.tag = nodes.inner.tag * 2
        nodes.next = other
        nodes.next.id = 5
        nodes[1].flag = other.id == 5 and not nodes[1].flag
        nodes.next = nil
        printf(
            "%%d %%g %%g %%g %%g %%lld %%g %%g %%.17g %%d %%g %%g\n",
            nodes.flag,
            nodes.small,
            nodes.count,
            nodes.index,
            nodes.id,
            nodes.big,
            nodes.value,
            nodes.inner.tag,
            nodes.inner.weight,
            nodes[1].flag,
            nodes[1].id,
            nodes[1].inner.tag
        )
        local bytes = nodes as uint8*
        for i = 0, 2 * SIZE - 1 do
            printf("%%g ", bytes[i])
        end
    end
    printf("\n")
    free(nodes)
    free(other)
    return 0
end
]]):format(size))
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ran)

    local n = ffi.new("nuppNativeProgramNode[2]")
    local other = ffi.new("nuppNativeProgramNode[1]")
    n[0].flag = true
    n[0].small = -5
    n[0].count = 65535
    n[0].count = n[0].count + 2
    n[0].index = -7
    n[0].index = n[0].index * 3
    n[0].id = 4000000000
    n[0].big = 9223372036854775807LL
    n[0].big = n[0].big + 1LL
    n[0].value = 2.5
    n[0].value = n[0].value * 3
    n[0].inner.tag = -9
    n[0].inner.weight = 0.1
    n[1].id = n[0].id + 1
    n[1].inner.tag = n[0].inner.tag * 2
    n[0].next = other
    ffi.cast("nuppNativeProgramNode *", n[0].next).id = 5
    n[1].flag = other[0].id == 5 and not n[1].flag
    n[0].next = nil
    test.eq(ran .. "\n", describe(n, 2))
end

-- What lowering refuses is reported where it was written, before anything is
-- compiled, so this needs no code generator.
function M.aCdefUnionsFieldIsRefusedWhereItIsRead()
    local executable, output = link([[
cdef union Bits
    whole: uint32
    half: uint16
end

cdef function calloc(count: uint64, size: uint64): voidptr

local function main(): int32
    local bits = calloc(1, 64) as Bits*
    @unsafe do
        return math.i32.wrap(bits.half)
    end
end
]])
    test.eq(executable, nil)
    assert(output:find("host.nupp:11:30: native: Bits is a cdef union, which a native program does not lay out", 1, true), output)
end

function M.aBitfieldStructsFieldIsRefused()
    local executable, output = link([[
cdef struct Flags
    low: uint32 : 3
    high: uint32 : 29
end

cdef function calloc(count: uint64, size: uint64): voidptr

local function main(): int32
    local flags = calloc(1, 64) as Flags*
    @unsafe do
        return math.i32.wrap(flags.low)
    end
end
]])
    test.eq(executable, nil)
    assert(output:find("native: field low of cdef struct Flags is a bitfield", 1, true), output)
end

function M.aWholeStructReadIsRefused()
    local executable, output = link([[
cdef struct Pair
    a: int32
    b: int32
end

cdef function calloc(count: uint64, size: uint64): voidptr

local function main(): int32
    local items = calloc(1, 64) as Pair*
    @unsafe do
        local first = items[0]
    end
    return 0
end
]])
    test.eq(executable, nil)
    assert(output:find("native: a native program reads a cdef struct's fields, not the whole struct", 1, true), output)
end

function M.anArrayFieldIsRefused()
    local executable, output = link([[
cdef struct Buffer
    bytes: uint8[4]
end

cdef function calloc(count: uint64, size: uint64): voidptr

local function main(): int32
    local buffer = calloc(1, 64) as Buffer*
    @unsafe do
        return math.i32.wrap(buffer.bytes[0])
    end
end
]])
    test.eq(executable, nil)
    assert(output:find("native: field bytes of cdef struct Buffer is a C array", 1, true), output)
end
function M.aTopLevelStatementIsRefusedWhereItIsWritten()
    local executable, output = link([[
print("not native")

local function main(): int32
    return 0
end
]])
    test.eq(executable, nil)
    assert(output:find("host.nupp:1:1: native: a native program's top level holds only", 1, true), output)
end

function M.aProgramWithoutMainIsRefused()
    local executable, output = link([[
local function helper(): int32
    return 1
end
]])
    test.eq(executable, nil)
    assert(output:find("native: a native program defines main", 1, true), output)
end

function M.anUntypedLuaValueIsRefused()
    local executable, output = link([[
local function main(): int32
    local t = {}
    return 0
end
]])
    test.eq(executable, nil)
    assert(output:find("native: a native program cannot evaluate tableExpr expressions", 1, true), output)
end

function M.outputIsRequired()
    local dir = project("local function main(): int32\n    return 0\nend\n")
    local status, output = run(("cd %s && NO_COLOR= %s aot --emit executable host.nupp"):format(quote(dir), quote(NUPP)))
    assert(status ~= 0, output)
    assert(output:find("--emit executable needs --output PATH", 1, true), output)
end

return M
