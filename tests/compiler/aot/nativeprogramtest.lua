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

--- A project holding `source` as `host.nupp`, and each of `modules` at the
--- path it is keyed by.
local function project(source, modules)
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p " .. quote(dir)) == 0)
    local manifest = assert(io.open(dir .. "/nupp.lua", "wb"))
    manifest:write('return {include = {"."}}\n')
    manifest:close()
    local handle = assert(io.open(dir .. "/host.nupp", "wb"))
    handle:write(source)
    handle:close()
    for path, text in pairs(modules or {}) do
        local file = dir .. "/" .. path
        assert(os.execute("mkdir -p " .. quote(file:match("^(.*)/"))) == 0)
        handle = assert(io.open(file, "wb"))
        handle:write(text)
        handle:close()
    end

    return dir
end

local function executableName(dir)
    return dir .. "/host" .. (jit.os == "Windows" and ".exe" or "")
end

--- Links `source` as a native program, with `modules` beside it, or returns
--- nil and what `nupp` said.
local function link(source, modules)
    local dir = project(source, modules)
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

-- A function-typed value is called through: a pointer a C function returns,
-- module state assigned one at run time, a local bound to a function of the
-- program's own, and a pointer that passed through a `voidptr`.
function M.aFunctionPointerFromCIsCalledThrough()
    requireCodegen()
    local executable, output = link(LUA_API .. [[
cdef function lua_atpanic(borrows L: voidptr, panicf: function(L: voidptr): int32): function(L: voidptr): int32
local handler: function(L: voidptr): int32

local function seven(L: voidptr): int32
    return 7
end

local function nine(L: voidptr): int32
    return 9
end

local function main(): int32
    local L = luaL_newstate()
    lua_atpanic(L, seven)
    handler = lua_atpanic(L, nine)
    local previous = lua_atpanic(L, seven)
    local direct = nine
    local erased = handler as voidptr
    local restored = erased as function(L: voidptr): int32
    local failed: integer = 0
    @unsafe do
        if handler(L) ~= 7 then
            failed += 1
        end
        if previous(L) ~= 9 then
            failed += 2
        end
        if direct(L) ~= 9 then
            failed += 4
        end
        if restored(L) ~= 7 then
            failed += 8
        end
    end
    lua_close(L)
    return math.i32.wrap(failed)
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ran)
end

-- A variadic function pointer passes its variadic arguments as a call to the
-- C function itself would, here raising through `luaL_error`.
function M.aVariadicFunctionPointerIsCalledThrough()
    requireCodegen()
    local executable, output = link(LUA_API .. [[
cdef function luaL_error(borrows L: voidptr, format: cstring, ...): int32

local raise: function(L: voidptr, format: cstring, ...): int32

local function fail(L: voidptr): int32
    return raise(L, "failed with %g and %s", 7, "more")
end

local function main(): int32
    raise = luaL_error
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
    assert(ran:find("failed with 7 and more", 1, true), ran)
end

-- A function-typed field of a `cdef struct` holds a C function pointer: one
-- written from a program function, from a C function and from a pointer a C
-- function returns, and each called back through the field.
function M.aFunctionPointerFieldIsWrittenAndCalledThrough()
    requireCodegen()
    local executable, output = link(LUA_API .. [[
cdef function lua_atpanic(borrows L: voidptr, panicf: function(L: voidptr): int32): function(L: voidptr): int32
cdef function calloc(count: uint64, size: uint64): voidptr
cdef function free(borrows p: voidptr)

cdef struct Handlers
    tag: int8
    panic: function(L: voidptr): int32
    fallback: (function(L: voidptr): int32)?
    after: int8
end

local function seven(L: voidptr): int32
    return 7
end

local function nine(L: voidptr): int32
    return 9
end

local function main(): int32
    local L = luaL_newstate()
    local handlers = calloc(1, 64) as Handlers*
    local failed: integer = 0
    @unsafe do
        handlers.tag = 3
        handlers.after = 5
        handlers.panic = seven
        lua_atpanic(L, nine)
        handlers.fallback = lua_atpanic(L, seven)
        if handlers.panic(L) ~= 7 then
            failed += 1
        end
        local fallback = handlers.fallback
        if fallback ~= nil then
            if fallback(L) ~= 9 then
                failed += 2
            end
            handlers.panic = fallback
        else
            failed += 16
        end
        local copied = handlers.panic
        if copied(L) ~= 9 then
            failed += 4
        end
        if handlers.tag ~= 3 or handlers.after ~= 5 then
            failed += 8
        end
        free(handlers as voidptr)
    end
    lua_close(L)
    return math.i32.wrap(failed)
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ran)
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

-- The operands every bit-operator case reads, as the native program binds them
-- and as plain LuaJIT does: negative, fractional and out-of-range numbers, an
-- established `int32`, and 64-bit integers of both signs.
local BIT_LOCALS_NATIVE = [[
    local a = -6
    local b = 10
    local f = 2.5
    local g = 3.5
    local big = 4294967298
    local huge = 13835058055282163712
    local i: int32 = math.i32.wrap(-5)
    local w: int64 = -3LL
    local u: uint64 = 9223372036854775808ULL
]]
local BIT_LOCALS_LUA = "local a, b, f, g, big, huge = -6, 10, 2.5, 3.5, 4294967298, 13835058055282163712 "
    .. "local i, w, u = -5, -3LL, 9223372036854775808ULL "

local BIT_EXPRESSIONS = {
    "a & b", "a | b", "a ~ b", "~a", "~0", "a << 3", "a >> 3", "a ~>> 3",
    "1 << 31", "1 << 32", "1 << -1", "a >> 33", "b << 37", "-1 >> 0",
    "f & 7", "g | 0", "big | 0", "~f", "b ~>> 1.5",
    "i & 255", "i >> 28", "i ~>> 1", "~i", "i << b",
    "w & 255", "w | 1", "w ~ -1", "~w", "w << 63", "w << 64", "w << -1",
    "w >> 1", "w ~>> 1", "w >> 65", "w & a", "a & w", "w & f", "w << b",
    "u & -1", "u & a", "u | w", "w ~ u", "u ~>> 4", "u >> 4", "~u", "u & huge", "w << u",
    "-2.5 | 0", "1e300 | 0", "w & 2.5", "w << 64.7", "9007199254740993 & w",
    "w & 1e300", "w | (0/0)", "w | (1/0)", "u & -1e30", "u | (0/0)", "u & (2^64 + 2^63)",
}

-- Each bit operator lowered natively gives what the same expression gives under
-- LuaJIT: numbers meet as 32-bit words, shift counts outside 0..31 or 0..63 are
-- masked, a fraction rounds, and an `int64` or `uint64` operand makes the
-- operation 64-bit, truncating a number beside it. A number out of 64-bit range,
-- NaN or an infinity converts as this machine's LuaJIT converts it. The program
-- exits with the first case that disagrees.
function M.bitOperatorsAgreeWithLuaJIT()
    requireCodegen()
    local lines = {}
    for index, expression in ipairs(BIT_EXPRESSIONS) do
        local result = assert(load(BIT_LOCALS_LUA .. "return " .. expression, "=" .. expression))()
        local expected = type(result) == "number" and ("%d"):format(result) or tostring(result)
        lines[#lines + 1] = ("    if (%s) ~= %s then\n        return %d\n    end\n"):format(expression, expected, index)
    end
    local executable, output = link(
        "local function main(): int32\n" .. BIT_LOCALS_NATIVE .. table.concat(lines) .. "    return 0\nend\n"
    )
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ("%s: %s"):format(tostring(BIT_EXPRESSIONS[status]), ran))
end

-- LuaJIT shifts a number by an `int64` count as a 32-bit number, which is not
-- the `int64` the checker gives the expression, so lowering refuses it.
-- A number shifted by a 64-bit count reads the count's low word, as LuaJIT
-- does, and stays a number.
function M.aNumberShiftedByA64BitCountAgreesWithLuaJIT()
    requireCodegen()
    local expected = assert(load([[
local count, big = 3LL, 0x100000021LL
local a = 1 << count
local b = -256 >> big
local c = -256 ~>> 9223372036854775780ULL
return (a + b % 1000 + c) % 251
]]))()
    local executable, output = link([[
local function main(): int32
    local count: int64 = 3LL
    local big: int64 = 0x100000021LL
    local wide: uint64 = 9223372036854775780ULL
    local a: integer = 1 << count
    local b: integer = -256 >> big
    local c: integer = -256 ~>> wide
    return math.i32.wrap((a + b % 1000 + c) % 251)
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, expected, ran)
end

-- 64-bit literals a double cannot hold exactly, hex ones among them, and the
-- ones LuaJIT wraps: a signed literal past 2^63, and a negated one.
local WIDE_LITERALS = {
    "0x7FFFFFFFFFFFFFE4ULL % 1000ULL", "0x7FFFFFFFFFFFFFE4ULL & 0xFFFFULL", "0x7FFFFFFFFFFFFFE4ULL >> 1",
    "0xFFFFFFFFFFFFFFFFULL", "0xFFFFFFFFFFFFFFFFULL % 1000ULL", "0x20000000000001ULL",
    "0xFFFFFFFFFFFFFFFFLL", "0x8000000000000001LL", "0x7FFFFFFFFFFFFFE4LL % 1000LL",
    "-0x1ULL", "-0x8000000000000000LL", "-0x7FFFFFFFFFFFFFE4LL", "0x000000000000000000ABLL",
    "9223372036854775809LL", "18446744073709551615LL", "-18446744073709551615ULL",
}

-- A 64-bit literal lowers to the exact value LuaJIT reads it as, hex spellings
-- above 2^53 included. The program exits with the first case that disagrees.
function M.wideLiteralsAgreeWithLuaJIT()
    requireCodegen()
    local lines = {}
    for index, expression in ipairs(WIDE_LITERALS) do
        local expected = tostring(assert(load("return " .. expression, "=" .. expression))())
        lines[#lines + 1] = ("    if (%s) ~= %s then\n        return %d\n    end\n"):format(expression, expected, index)
    end
    local executable, output = link("local function main(): int32\n" .. table.concat(lines) .. "    return 0\nend\n")
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ("%s: %s"):format(tostring(WIDE_LITERALS[status]), ran))
end

-- A compound bit assignment stores what the operator gives, as LuaJIT does.
function M.bitCompoundAssignmentsAgreeWithLuaJIT()
    requireCodegen()
    local expected = assert(load("local x = 12 x = x & 10 x = x | 1 x = x << 2 x = x >> 1 x = x ~>> 33 return x"))()
    local executable, output = link([[
local function main(): int32
    local x: integer = 12
    x &= 10
    x |= 1
    x <<= 2
    x >>= 1
    x ~>>= 33
    return math.i32.wrap(x)
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, expected, ran)

    -- On `int64` and `uint64` locals the same operators keep all 64 bits.
    local w, u = assert(load([[
local w = -3LL w = w << 40 w = w & -4096LL w = w | 5 w = w ~>> 3 w = w >> 1
local u = 0ULL - 3ULL u = u << 4 u = u & (0ULL - 65536ULL) u = u | 7 u = u >> 2 u = u ~>> 1
return w, u
]]))()
    executable, output = link([[
cdef function printf(borrows format: cstring, ...): int32

local function main(): int32
    local w: int64 = -3LL
    w <<= 40
    w &= -4096LL
    w |= 5
    w ~>>= 3
    w >>= 1
    local u: uint64 = 0ULL - 3ULL
    u <<= 4
    u &= 0ULL - 65536ULL
    u |= 7
    u >>= 2
    u ~>>= 1
    printf("%lld %llu\n", w, u)
    return 0
end
]])
    assert(executable ~= nil, output)
    status, ran = run(quote(executable))
    test.eq(status, 0, ran)
    test.eq(ran, tostring(w):match("^-?%d+") .. " " .. tostring(u):match("^%d+"))
end

-- A compound arithmetic assignment on an `int64` or `uint64` local keeps all 64
-- bits, as the binary operator does. LuaJIT has no `//`, so the reference
-- divides with `/`, which agrees while the operands are not negative.
function M.wideArithmeticCompoundAssignmentsAgreeWithLuaJIT()
    requireCodegen()
    local w, u = assert(load([[
local w = 7LL w = w + 2LL w = w * 3 w = w / 2LL w = w - 20 w = w % 5 w = w / 1
w = w + 4294967296LL w = w * 3 w = w - 1
local u = 0ULL - 3ULL u = u + 1 u = u - 2ULL u = u * 3ULL u = u / 7 u = u % 1000003ULL u = u / 2ULL
return w, u
]]))()
    local executable, output = link([[
cdef function printf(borrows format: cstring, ...): int32

local function main(): int32
    local w: int64 = 7LL
    w += 2LL
    w *= 3
    w //= 2LL
    w -= 20
    w %= 5
    w /= 1
    w += 4294967296LL
    w *= 3
    w -= 1
    local u: uint64 = 0ULL - 3ULL
    u += 1
    u -= 2ULL
    u *= 3ULL
    u //= 7
    u %= 1000003ULL
    u /= 2ULL
    printf("%lld %llu\n", w, u)
    return 0
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ran)
    test.eq(ran, tostring(w):match("^-?%d+") .. " " .. tostring(u):match("^%d+"))
end

local INT64_MIN = "(-9223372036854775807LL - 1LL)"
local INT64_MAX = "9223372036854775807LL"
local UINT64_MAX = "(0ULL - 1ULL)"

-- Each case is a call `main` reports, as `name value`, through `printf`.
local DIVISION_CASES = {}
for _, pair in ipairs({
    {"7LL", "2LL"},
    {"-7LL", "2LL"},
    {"7LL", "-2LL"},
    {"-7LL", "-2LL"},
    {"-6LL", "3LL"},
    {"7LL", "0LL"},
    {"-7LL", "0LL"},
    {"0LL", "0LL"},
    {INT64_MIN, "-1LL"},
    {INT64_MIN, "1LL"},
    {INT64_MIN, "-2LL"},
    {INT64_MAX, "-1LL"},
    {INT64_MIN, INT64_MIN},
    {"-5LL", INT64_MIN},
}) do
    for _, op in ipairs({"div", "mod", "floor"}) do
        DIVISION_CASES[#DIVISION_CASES + 1] = ("signed(%q, %s(%s, %s))"):format(op, op, pair[1], pair[2])
    end
end
for _, pair in ipairs({
    {"7ULL", "2ULL"},
    {"(0ULL - 7ULL)", "2ULL"},
    {"7ULL", "0ULL"},
    {UINT64_MAX, UINT64_MAX},
    {"5ULL", UINT64_MAX},
    {UINT64_MAX, "3ULL"},
}) do
    for _, op in ipairs({"udiv", "umod", "ufloor"}) do
        DIVISION_CASES[#DIVISION_CASES + 1] = ("unsigned(%q, %s(%s, %s))"):format(op, op, pair[1], pair[2])
    end
end
for _, call in ipairs({
    -- `//` tests the operands' signs as written, before they meet as `uint64`.
    "unsigned('mixedfloor', mixedfloor(-7LL, 2ULL))",
    "unsigned('mixedfloor', mixedfloor(7LL, 2ULL))",
    -- A number converts to `int64` by truncation; `//` still reads its sign.
    "signed('numberfloor', numberfloor(-7LL, 2.5))",
    "signed('numberfloor', numberfloor(7LL, -2.5))",
    "signed('numberfloor', numberfloor(7LL, -0.5))",
    "signed('numberdiv', numberdiv(7LL, -0.5))",
    "signed('numbermod', numbermod(-7LL, 2.5))",
}) do
    DIVISION_CASES[#DIVISION_CASES + 1] = call
end

local DIVISION = [[
cdef function printf(borrows format: cstring, ...): int32

local function signed(name: cstring, result: int64): int32
    return printf("%s %lld\n", name, result)
end

local function unsigned(name: cstring, result: uint64): int32
    return printf("%s %llu\n", name, result)
end

local function div(a: int64, b: int64): int64
    return a / b
end

local function mod(a: int64, b: int64): int64
    return a % b
end

local function floor(a: int64, b: int64): int64
    return a // b
end

local function udiv(a: uint64, b: uint64): uint64
    return a / b
end

local function umod(a: uint64, b: uint64): uint64
    return a % b
end

local function ufloor(a: uint64, b: uint64): uint64
    return a // b
end

local function mixedfloor(a: int64, b: uint64): uint64
    return a // b
end

local function numberfloor(a: int64, b: number): int64
    return a // b
end

local function numberdiv(a: int64, b: number): int64
    return a / b
end

local function numbermod(a: int64, b: number): int64
    return a % b
end

local function main(): int32
    ]] .. table.concat(DIVISION_CASES, "\n    ") .. [[

    return 0
end
]]

-- `/`, `%` and `//` over `int64` and `uint64` answer what the same program does
-- under LuaJIT, compiled to Lua by the same `nupp`: dividing by zero gives
-- INT64_MIN, as does INT64_MIN / -1, and `%` takes the dividend's sign.
function M.wideDivisionAgreesWithLuaJIT()
    requireCodegen()
    local executable, output = link(DIVISION)
    assert(executable ~= nil, output)
    local status, native = run(quote(executable))
    test.eq(status, 0, native)

    local dir = executable:match("^(.*)/[^/]*$")
    local lua
    status, lua = run(("cd %s && NO_COLOR= %s lsp artifact --kind lua host.nupp"):format(quote(dir), quote(NUPP)))
    test.eq(status, 0, lua)
    local chunk = assert(io.open(dir .. "/host.lua", "wb"))
    chunk:write(lua, "\nos.exit(main())\n")
    chunk:close()
    -- The runtime is found relative to `build/` rather than through an
    -- absolute LUA_PATH: under Git Bash `HERE` is spelled `/c/...`, which a
    -- native Windows `luajit` cannot open. `dir` is already native.
    local reference
    status, reference = run(
        ("cd %s && LUA_PATH='./?.lua;;' luajit -joff %s"):format(quote(HERE .. "/../build"), quote(dir .. "/host.lua"))
    )
    test.eq(status, 0, reference)

    test.eq(select(2, native:gsub("\n", "")) + 1, #DIVISION_CASES, native)
    test.eq(native, reference)
    -- Anchors that do not rest on the Lua backend: INT64_MIN / -1, its
    -- remainder, a division by zero, and a negative dividend's remainder.
    local lines = {}
    for line in native:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    test.eq(lines[1], "div 3")
    test.eq(lines[5], "mod -1")
    test.eq(lines[6], "floor -4")
    test.eq(lines[16], "div -9223372036854775808")
    test.eq(lines[25], "div -9223372036854775808")
    test.eq(lines[26], "mod 0")
    test.eq(lines[27], "floor -9223372036854775808")
end

function M.wideExponentiationIsRefused()
    local executable, output = link([[
local function main(): int32
    local wide: int64 = 3LL
    local squared: int64 = wide ^ 2LL
    return 0
end
]])
    test.eq(executable, nil)
    assert(output:find("host.nupp:3:", 1, true), output)
    assert(output:find("native: a native program does not lower ^ over 64-bit integers", 1, true), output)
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
    local fields = ("%d %g %g %g %.10g %s %g %g %.17g %d %.10g %g\n"):format(
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
            "%%d %%g %%g %%g %%.10g %%lld %%g %%g %%.17g %%d %%.10g %%g\n",
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
    test.eq(ran, (describe(n, 2):gsub("%s+$", "")))
end

ffi.cdef([[
typedef struct {
    int64_t big;
    uint64_t ubig;
    uint16_t count;
    int8_t small;
    uint32_t id;
} nuppNativeProgramWide;
]])

-- Numbers NaN, infinite, past 64 bits or negative where a C integer is unsigned,
-- each converted as `lj_cconv_ct_ct` converts it.
local CONVERSIONS = {
    "0 / 0", "1 / 0", "-1 / 0", "1e300", "-1e300", "2 ^ 63", "-(2 ^ 63)", "2 ^ 64",
    "2 ^ 64 + 2 ^ 63", "2 ^ 63 + 2 ^ 11", "-1", "-2.5", "4294967298", "3e9", "-3e9", "1e10",
}

-- Each number stored to an `int64` or `uint64` local, and to `cdef struct`
-- fields of 64 bits and narrower, holds what the same store holds under this
-- machine's LuaJIT, out of range and for NaN or an infinity included, where a
-- plain `fptosi` or `fptoui` would be poison.
function M.numbersConvertToCIntegersAsUnderLuaJIT()
    requireCodegen()
    local calls = {}
    for _, expression in ipairs(CONVERSIONS) do
        calls[#calls + 1] = ("    show(%s, wide)\n"):format(expression)
    end
    local executable, output = link([[
cdef function calloc(count: uint64, size: uint64): voidptr
cdef function free(borrows p: voidptr)
cdef function printf(borrows format: cstring, ...): int32

cdef struct Wide
    big: int64
    ubig: uint64
    count: uint16
    small: int8
    id: uint32
end

local function show(n: number, wide: Wide*): nil
    local signed: int64 = n as int64
    local unsigned: uint64 = n as uint64
    @unsafe do
        wide.big = n
        wide.ubig = n
        wide.count = n
        wide.small = n
        wide.id = n
        printf(
            "%lld %llu %lld %llu %g %g %.10g\n",
            signed,
            unsigned,
            wide.big,
            wide.ubig,
            wide.count,
            wide.small,
            wide.id
        )
    end
end

local function main(): int32
    local wide = calloc(1, 64) as Wide*
]] .. table.concat(calls) .. [[
    free(wide)
    return 0
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ran)

    local printed = {}
    for line in ran:gmatch("[^\r\n]+") do
        printed[#printed + 1] = line
    end
    local wide = ffi.new("nuppNativeProgramWide[1]")
    for index, expression in ipairs(CONVERSIONS) do
        local n = assert(load("return " .. expression))()
        wide[0].big = n
        wide[0].ubig = n
        wide[0].count = n
        wide[0].small = n
        wide[0].id = n
        local expected = ("%s %s %s %s %g %g %.10g"):format(
            (tostring(ffi.new("int64_t", n)):gsub("LL$", "")),
            (tostring(ffi.new("uint64_t", n)):gsub("ULL$", "")),
            (tostring(wide[0].big):gsub("LL$", "")),
            (tostring(wide[0].ubig):gsub("ULL$", "")),
            wide[0].count,
            wide[0].small,
            wide[0].id
        )
        test.eq(printed[index], expected, expression)
    end
    test.eq(#printed, #CONVERSIONS, ran)
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

function M.anArrayOfUnknownSizeIsRefused()
    local executable, output = link([[
local scratch: int32[?]

local function main(): int32
    return 0
end
]])
    test.eq(executable, nil)
    assert(output:find("native: module data scratch is not a C array of a fixed size", 1, true), output)
end
function M.aFunctionPointerWithoutACSignatureIsRefusedWhereItIsCalled()
    local executable, output = link([[
local apply: function(values: {number}): int32

local function main(): int32
    return apply({})
end
]])
    test.eq(executable, nil)
    assert(output:find("host.nupp:4:12: native: parameter 1 of apply has type ", 1, true), output)
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

-- A module a program requires: private state of each kind, a `cdef struct`
-- held in place and handed to C, an exported constant and exported functions.
local COUNTER = [[
module app.counter

cdef struct Tally
    count: int32
    total: number
end

cdef function memset(s: Tally*, c: int32, n: uint64): voidptr

local tally: Tally
local step: int32 = 2
local label: cstring = "counter"
local latest: voidptr? = nil
local started = false
export const START = 40

local function bumped(by: int32): int32
    tally.count = math.i32.wrap(tally.count + by)
    tally.total += by
    return tally.count
end

export function reset(): nil
    memset(tally, 0, 16)
    step = math.i32.wrap(2)
    latest = nil
    started = true
end

export function bump(): int32
    step = math.i32.wrap(step + 1)
    latest = tally
    return bumped(step)
end

export function name(): cstring
    if latest == nil or not started then
        return "unset"
    end
    return label
end

export function total(): number
    return tally.total
end
]]

-- A program spans modules: `main` calls into the module it requires, by its
-- binding and by names a pattern selects, and each module's state, its
-- private `step` and the entry's own, is its own.
function M.aProgramSpansTheModulesItRequires()
    requireCodegen()
    local executable, output = link([[
cdef function puts(borrows s: cstring): int32
local counter = require("app.counter")
const {bump, START as LIMIT} = require("app.counter")

local runs: int32 = 0
local step: number = 0.5

local function main(): int32
    counter.reset()
    counter.bump()
    bump()
    runs = math.i32.wrap(runs + 1)
    puts(counter.name())
    return math.i32.wrap(math.floor(counter.bump() + counter.total() + LIMIT + runs + step * 2))
end
]], {["app/counter.nupp"] = COUNTER})
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    -- Steps 3, 4 and 5: a count and total of 12, then 40, one run and 2 * 0.5.
    test.eq(status, 66, ran)
    test.eq(ran, "counter")
end

-- Module state starts as a literal, a const or zero, and is read and written by
-- every function of its module across calls.
function M.moduleStateKeepsItsValueAcrossCalls()
    requireCodegen()
    local executable, output = link([[
cdef struct Point
    x: int32
    y: number
end

const BASE = 5

local calls: int32 = BASE
local scale: number = -1.5
local wide: int64 = 3LL
local flag: boolean = true
local origin: Point
local cursor: voidptr? = nil

local function step(): nil
    calls = math.i32.wrap(calls + 1)
    scale *= -2
    wide += 1LL
    flag = not flag
    origin.x = math.i32.wrap(origin.x + 2)
    origin.y += 0.25
    cursor = origin
end

local function main(): int32
    step()
    step()
    local failed: integer = 0
    if calls ~= 7 then
        failed += 1
    end
    if scale ~= -6 then
        failed += 2
    end
    if wide ~= 5LL then
        failed += 4
    end
    if not flag then
        failed += 8
    end
    @unsafe do
        if origin.x ~= 4 or origin.y ~= 0.5 or cursor == nil then
            failed += 16
        end
    end
    return math.i32.wrap(failed)
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ran)
end

-- What a native library publishes: an exported function under its own name,
-- beside module state, with no `main`.
local LIBRARY = [[
module host

local calls: int32 = 0

export function nupp_native_twice(n: int32): int32
    calls = math.i32.wrap(calls + 1)
    return math.i32.wrap(n * 2 + calls)
end

export function nupp_native_hidden(): int32
    return 7
end
]]

local SHARED = jit.os == "Windows" and ".dll" or jit.os == "OSX" and ".dylib" or ".so"

--- Builds `source` as `emit`, written to `name` in its project, or returns nil
--- and what `nupp` said.
local function library(source, emit, name, extra)
    local dir = project(source)
    local output = dir .. "/" .. name
    local status, said = run(
        ("cd %s && NO_COLOR= %s aot --emit %s --output %s %s host.nupp"):format(
            quote(dir),
            quote(NUPP),
            emit,
            quote(output),
            extra or ""
        )
    )
    if status ~= 0 then
        return nil, said, dir
    end

    return output, said, dir
end

-- A static library needs no `main`, and a program linking it with `--archive`
-- calls what it exports by name.
function M.aStaticLibraryLinksIntoAProgram()
    requireCodegen()
    local archive, output = library(LIBRARY, "static-library", "libtwice.a")
    assert(archive ~= nil, output)
    local dir = project([[
cdef function nupp_native_twice(n: int32): int32

local function main(): int32
    nupp_native_twice(1)
    return nupp_native_twice(20)
end
]])
    local executable = executableName(dir)
    local status
    status, output = run(
        ("cd %s && NO_COLOR= %s aot --emit executable --archive %s --output %s host.nupp"):format(
            quote(dir),
            quote(NUPP),
            quote(archive),
            quote(executable)
        )
    )
    test.eq(status, 0, output)
    local ran
    status, ran = run(quote(executable))
    test.eq(status, 42, ran)
end

local ffi = require("ffi")

pcall(ffi.cdef, "int nupp_native_twice(int n); int nupp_native_hidden(void);")

-- A shared library exports every function a module exports, and with
-- `--exports` exactly the symbols the list names.
function M.aSharedLibraryExportsWhatItsListNames()
    requireCodegen()
    local everything, output = library(LIBRARY, "shared-library", "libtwice" .. SHARED)
    assert(everything ~= nil, output)
    local loaded = ffi.load(everything)
    test.eq(loaded.nupp_native_twice(20), 41)
    test.eq(loaded.nupp_native_twice(20), 42)
    test.eq(loaded.nupp_native_hidden(), 7)

    local dir = project(LIBRARY)
    local list = assert(io.open(dir .. "/host.exports", "wb"))
    list:write("# What the library publishes.\nnupp_native_twice\n")
    list:close()
    local listed
    listed, output = library(LIBRARY, "shared-library", "liblisted" .. SHARED, "--exports " .. quote(dir .. "/host.exports"))
    assert(listed ~= nil, output)
    loaded = ffi.load(listed)
    test.eq(loaded.nupp_native_twice(1), 3)
    assert(not pcall(function()
        return loaded.nupp_native_hidden
    end), "a symbol the export list leaves out was exported")
end

-- An export list is read, and a line that names no symbol refused, before
-- anything is compiled, so this needs no code generator.
function M.anExportListIsReadBeforeLinking()
    local dir = project(LIBRARY)
    local list = assert(io.open(dir .. "/bad.exports", "wb"))
    list:write("nupp_native_twice\nnot a symbol\n")
    list:close()
    local status, output = run(
        ("cd %s && NO_COLOR= %s aot --emit shared-library --exports bad.exports --output lib.so host.nupp"):format(
            quote(dir),
            quote(NUPP)
        )
    )
    assert(status ~= 0, output)
    assert(output:find("bad.exports: line 2 names no symbol: not a symbol", 1, true), output)
end

function M.aStaticLibraryTakesNoExportList()
    local dir = project(LIBRARY)
    local status, output = run(
        ("cd %s && NO_COLOR= %s aot --emit static-library --exports x --output lib.a host.nupp"):format(
            quote(dir),
            quote(NUPP)
        )
    )
    assert(status ~= 0, output)
    assert(output:find("--exports names what an executable or shared library exports", 1, true), output)
end

function M.moduleStateStartsAsALiteral()
    local executable, output = link([[
local start: int32 = math.i32.wrap(3)

local function main(): int32
    return start
end
]])
    test.eq(executable, nil)
    assert(
        output:find("host.nupp:1:22: native: module state start starts as a literal, nil, a const, a function", 1, true),
        output
    )
end

-- A refusal in a module the program requires names that module's file.
function M.aRefusalInARequiredModuleNamesItsFile()
    local executable, output = link([[
local helper = require("app.helper")

local function main(): int32
    return helper.value()
end
]], {
        ["app/helper.nupp"] = [[
module app.helper

export function value(): int32
    local t = {}
    return 0
end
]],
    })
    test.eq(executable, nil)
    assert(output:find("helper.nupp:4:15: native: a native program cannot evaluate tableExpr expressions", 1, true), output)
end



--[[
C arrays and module data. What each lowers to is read from the module text, so
these cases need no code generator; the programs after them are run, and the
library's data read through LuaJIT's FFI, where one is available.
]]

local parser = require("nupp.compiler.syntax.parser")
local fragment = require("helpers.fragment")
local sharedEnv = require("nupp.compiler.project.env").new(require("helpers.paths").tests .. "/..")

local TRIPLE = "x86_64-unknown-linux-gnu"

--- The module `source` lowers to for x86-64 Linux, or nil and the refusal's
--- message.
local function lowerData(source)
    local tree = parser.parse(source, "host.nupp")
    if #tree.errors > 0 then
        error("syntax: " .. tree.errors[1].message, 2)
    end
    local diagnostics = fragment.check(tree, "host.nupp", sharedEnv)
    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.severity == nil or diagnostic.severity == "error" then
            error("check: " .. diagnostic.code .. " " .. tostring(diagnostic.msg), 2)
        end
    end
    local native = require("nupp.compiler.aot.llvm.native")
    local ir, problem = native.program({{name = "", tree = tree.root}}, TRIPLE, "", {library = true})
    if ir == nil then
        return nil, problem.message
    end

    return ir
end

local function contains(ir, fragmentText)
    assert(ir:find(fragmentText, 1, true), "expected `" .. fragmentText .. "` in:\n" .. ir)
end

local ARRAYS = [[
module host

cdef struct Header
    tag: int8
    words: uint64[4]
    grid: float[3][2]
    flags: boolean[2]
end

local function twice(n: int32): int32
    return math.i32.wrap(n * 2)
end

const HEADER_SIZE = ffi.sizeof(Header)
const POWERS = ffi.new<const uint64[4]>({1ULL, 10ULL, 18446744073709551615ULL})
const HALVES: number[2] = ffi.new<number[2]>({0.5, -1.5})
const TABLE = ffi.new<const voidptr[5]>({
    7 as voidptr,
    HEADER_SIZE as voidptr,
    ffi.offsetof(Header, "grid") as voidptr,
    ffi.alignof(Header) as voidptr,
    twice as voidptr
})
const MATRIX = ffi.new<const int16[3][2]>({{1, 2, 3}, {4}})
local counts: int32[3]
local seen = ffi.new<boolean[2]>({true})
]]

-- An array of `const` elements is read-only data, and any other a writable
-- global, whether its binding is `const` or not; each has its elements in order
-- and the rest zero, a layout query is the target's answer, and a function as
-- an address is its symbol.
function M.constantArraysAndArrayStateLowerToData()
    local ir = assert(lowerData(ARRAYS .. [[

export function nupp_native_read(i: int32): number
    counts[i] = math.i32.wrap(counts[i] + 1)
    seen[1] = counts[0] > 0
    return MATRIX[1][0] + HALVES[1]
end

export function nupp_native_power(i: int32): uint64
    return POWERS[i]
end
]]))
    contains(ir, "@nupp.POWERS = internal constant [4 x i64] [i64 1, i64 10, i64 18446744073709551615, i64 0], align 8")
    contains(ir, "@nupp.HALVES = internal global [2 x double] [double 0x3FE0000000000000, double 0xBFF8000000000000], align 8")
    contains(
        ir,
        "@nupp.TABLE = internal constant [5 x ptr] [ptr inttoptr (i64 7 to ptr), ptr inttoptr (i64 72 to ptr), "
            .. "ptr inttoptr (i64 40 to ptr), ptr inttoptr (i64 8 to ptr), ptr @nupp.twice], align 8"
    )
    contains(
        ir,
        "@nupp.MATRIX = internal constant [2 x [3 x i16]] [[3 x i16] [i16 1, i16 2, i16 3], "
            .. "[3 x i16] [i16 4, i16 0, i16 0]], align 2"
    )
    contains(ir, "@nupp.counts = internal global [3 x i32] zeroinitializer, align 4")
    contains(ir, "@nupp.seen = internal global [2 x i8] [i8 1, i8 0], align 1")
    contains(ir, "getelementptr i64, ptr @nupp.POWERS")
    contains(ir, "getelementptr [3 x i16], ptr @nupp.MATRIX")
end

-- A C array field is indexed in place, a nested one row by row, and a
-- `boolean` element is a byte as a field is.
function M.cArrayFieldsAreIndexedInPlace()
    local ir = assert(lowerData(ARRAYS .. [[

export function nupp_native_fill(header: Header*, i: int32): number
    @unsafe do
        header.words[i] = 5ULL
        header.words[3] += 1ULL
        header.grid[1][2] = 1.5
        header.flags[1] = true
        if header.flags[1] then
            return header.grid[1][2]
        end
    end
    return 0
end
]]))
    -- `words` sits at offset 8, `grid` at 40 and `flags` at 64.
    contains(ir, "getelementptr i8, ptr %")
    contains(ir, ", i64 8")
    contains(ir, ", i64 40")
    contains(ir, ", i64 64")
    contains(ir, "getelementptr [3 x float], ptr %")
    contains(ir, "zext i1 true to i8")
end

-- Exported data, an array or a struct `ffi.new` makes, is a C data symbol under
-- its own name, read-only when its type is `const` and with the visibility
-- `@visibility` gives it.
function M.exportedDataIsASymbolWithItsVisibility()
    local ir = assert(lowerData([[
module runtime

local ffi = require("ffi")

cdef struct Header
    count: int32
end

local function first(n: int32): int32
    return n
end

export const runtime_table = ffi.new<const voidptr[2]>({1 as voidptr, first as voidptr})

@visibility("hidden")
export const runtime_hidden = ffi.new<const uint32[2]>({3, 4})

export const runtime_calls = ffi.new<int32[1]>({2})

@visibility("hidden")
export const runtime_scratch = ffi.new<uint8[16]>()

export const runtime_header = ffi.new<Header>()

@visibility("hidden")
export function runtime_bump(): int32
    runtime_calls[0] = math.i32.wrap(runtime_calls[0] + runtime_hidden[1])
    runtime_header.count = runtime_calls[0]
    return runtime_calls[0]
end
]]))
    contains(ir, "@runtime_table = constant [2 x ptr] [ptr inttoptr (i64 1 to ptr), ptr @nupp.first], align 8")
    contains(ir, "@runtime_hidden = hidden constant [2 x i32] [i32 3, i32 4], align 4")
    contains(ir, "@runtime_calls = global [1 x i32] [i32 2], align 4")
    contains(ir, "@runtime_scratch = hidden global [16 x i8] zeroinitializer, align 1")
    contains(ir, "@runtime_header = global [4 x i8] zeroinitializer, align 4")
    contains(ir, "define hidden i32 @runtime_bump(")
end

function M.aConstantArrayIsNeverWritten()
    local ir, message = lowerData(ARRAYS .. [[

export function nupp_native_write(i: int32): nil
    POWERS[i] = 2ULL
end
]])
    test.eq(ir, nil)
    test.eq(message, "POWERS is read-only data, which is never written")
end

function M.aWholeArrayIsNeverAssigned()
    local ir, message = lowerData([[
module host

cdef struct Pair
    words: int32[2]
end

export function nupp_native_copy(a: Pair*, b: Pair*): nil
    @unsafe do
        a.words = b.words
    end
end
]])
    test.eq(ir, nil)
    test.eq(message, "a native program assigns a C array's elements, not the whole array")
end

function M.anArrayHoldsNoMoreThanItsCount()
    local ir, message = lowerData([[
local values = ffi.new<int32[2]>({1, 2, 3})
]])
    test.eq(ir, nil)
    test.eq(message, "module data values holds 2 elements, not 3")
end

function M.visibilityIsForAnExport()
    local ir, message = lowerData([[
@visibility("hidden")
local function helper(): int32
    return 1
end
]])
    test.eq(ir, nil)
    test.eq(message, "@visibility applies to what a native program exports")
end

-- The same program run: arrays read and written, layout queries in a body,
-- and C array fields filled through a pointer.
function M.arraysAndLayoutQueriesRunAsWritten()
    requireCodegen()
    local executable, output = link(ARRAYS .. [[
cdef function calloc(count: uint64, size: uint64): voidptr
cdef function free(borrows p: voidptr)

local function main(): int32
    local header = calloc(1, HEADER_SIZE) as Header*
    local total: number = 0
    @unsafe do
        for i = 0, 3 do
            header.words[i] = POWERS[i]
        end
        header.grid[1][2] = HALVES[0]
        header.flags[1] = seen[0]
        if not header.flags[1] or header.words[2] ~= 18446744073709551615ULL then
            return 1
        end
        total = header.grid[1][2] + MATRIX[1][0] + MATRIX[0][2]
    end
    free(header as voidptr)
    counts[2] = 30
    -- 0.5 + 4 + 3, a size of 72, an offset of 40 and 30.
    return math.i32.wrap(math.floor(total) + ffi.sizeof(Header) - ffi.offsetof(Header, "grid") + counts[2])
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 69, ran)
end

pcall(ffi.cdef, [[
extern const uint64_t nupp_native_powers[3];
extern const int32_t nupp_native_hidden_powers[3];
extern int32_t nupp_native_calls[1];
]])

local DATA_LIBRARY = [[
module host

export const nupp_native_powers = ffi.new<const uint64[3]>({1ULL, 10ULL, 100ULL})

@visibility("hidden")
export const nupp_native_hidden_powers = ffi.new<const int32[3]>({2, 20, 200})

export const nupp_native_calls = ffi.new<int32[1]>({4})

export function nupp_native_twice(n: int32): int32
    nupp_native_calls[0] = math.i32.wrap(nupp_native_calls[0] + 1)
    return math.i32.wrap(n * 2 + nupp_native_hidden_powers[0])
end
]]

-- A C consumer, here LuaJIT's FFI, reads a shared library's exported data by
-- name; a hidden symbol stays inside the library, and `--exports` lists data as
-- it lists functions.
function M.aSharedLibraryExportsItsData()
    requireCodegen()
    local built, output = library(DATA_LIBRARY, "shared-library", "libdata" .. SHARED)
    assert(built ~= nil, output)
    local loaded = ffi.load(built)
    test.eq(tonumber(loaded.nupp_native_powers[2]), 100)
    test.eq(loaded.nupp_native_calls[0], 4)
    test.eq(loaded.nupp_native_twice(20), 42)
    test.eq(loaded.nupp_native_calls[0], 5)
    assert(not pcall(function()
        return loaded.nupp_native_hidden_powers
    end), "a hidden symbol was exported")

    local dir = project(DATA_LIBRARY)
    local list = assert(io.open(dir .. "/host.exports", "wb"))
    list:write("nupp_native_powers\n")
    list:close()
    local listed
    listed, output = library(DATA_LIBRARY, "shared-library", "libdatalisted" .. SHARED, "--exports " .. quote(dir .. "/host.exports"))
    assert(listed ~= nil, output)
    loaded = ffi.load(listed)
    test.eq(tonumber(loaded.nupp_native_powers[1]), 10)
    assert(not pcall(function()
        return loaded.nupp_native_calls
    end), "a symbol the export list leaves out was exported")
end

-- A static archive's data links into a program by name, as its functions do.
function M.aStaticLibrarysDataLinksIntoAProgram()
    requireCodegen()
    local archive, output = library(DATA_LIBRARY, "static-library", "libdata.a")
    assert(archive ~= nil, output)
    local dir = project([[
cdef function nupp_native_twice(n: int32): int32

local function main(): int32
    return nupp_native_twice(20)
end
]])
    local executable = executableName(dir)
    local status
    status, output = run(
        ("cd %s && NO_COLOR= %s aot --emit executable --archive %s --output %s host.nupp"):format(
            quote(dir),
            quote(NUPP),
            quote(archive),
            quote(executable)
        )
    )
    test.eq(status, 0, output)
    local ran
    status, ran = run(quote(executable))
    test.eq(status, 42, ran)
end


-- `jit.os` and `jit.arch` name the target, and a test of them is decided while
-- compiling: a clause it rules out is not lowered, so it may call what only
-- another platform has.
local TARGETED = [[
cdef function GetCurrentProcessId(): uint32
cdef function getpid(): int32
cdef function puts(borrows s: cstring): int32

local function main(): int32
    puts(jit.os)
    puts(jit.arch)
    if jit.os == "Windows" then
        if GetCurrentProcessId() == 0 then
            return 1
        end
        return 7
    elseif jit.os ~= "OSX" and not (jit.arch == "x64") then
        if getpid() <= 0 then
            return 1
        end
        return 8
    else
        if getpid() <= 0 then
            return 1
        end
        return 9
    end
end
]]

--- The module `source` lowers to for `triple`, or nil and the refusal.
local function lower(source, triple)
    local parser = require("nupp.compiler.syntax.parser")
    local check = require("helpers.fragment")
    local env = require("nupp.compiler.project.env").new(require("helpers.paths").tests .. "/..")
    local tree = parser.parse(source, "host.nupp")
    assert(#tree.errors == 0, tree.errors[1] and tree.errors[1].message)
    local diagnostics = check.check(tree, "host.nupp", env)
    assert(#diagnostics == 0, diagnostics[1] and diagnostics[1].code .. " " .. tostring(diagnostics[1].msg))
    local ir, problem = require("nupp.compiler.aot.llvm.native").module(tree.root, triple, "")
    if ir == nil then
        return nil, problem.message
    end

    return ir
end

local function calls(ir, symbol)
    return ir:find("call [^\n]*@" .. symbol .. "%(") ~= nil
end

function M.aTargetTestLowersOnlyTheBranchItSelects()
    for triple, expected in pairs({
        ["x86_64-pc-windows-msvc"] = {status = 7, os = "Windows", arch = "x64", windows = true},
        ["aarch64-pc-windows-msvc"] = {status = 7, os = "Windows", arch = "arm64", windows = true},
        ["aarch64-unknown-linux-gnu"] = {status = 8, os = "Linux", arch = "arm64"},
        ["i686-unknown-linux-gnu"] = {status = 8, os = "Linux", arch = "x86"},
        ["x86_64-unknown-linux-gnu"] = {status = 9, os = "Linux", arch = "x64"},
        ["aarch64-apple-darwin"] = {status = 9, os = "OSX", arch = "arm64"},
    }) do
        local ir = assert(lower(TARGETED, triple))
        test.eq(calls(ir, "GetCurrentProcessId"), expected.windows == true, triple)
        test.eq(calls(ir, "getpid"), expected.windows ~= true, triple)
        assert(ir:find("ret i32 " .. expected.status, 1, true), triple .. ":\n" .. ir)
        for _, other in ipairs({7, 8, 9}) do
            if other ~= expected.status then
                assert(not ir:find("ret i32 " .. other, 1, true), triple .. ":\n" .. ir)
            end
        end
        assert(ir:find('c"' .. expected.os .. '\\00"', 1, true), triple .. ":\n" .. ir)
        assert(ir:find('c"' .. expected.arch .. '\\00"', 1, true), triple .. ":\n" .. ir)
    end
end

-- Linked and run for this machine, the program takes the branch LuaJIT's own
-- `jit.os` and `jit.arch` select, and links without the other platform's
-- functions.
function M.aTargetedProgramRunsTheBranchForThisMachine()
    requireCodegen()
    local executable, output = link(TARGETED)
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    local expected = 9
    if jit.os == "Windows" then
        expected = 7
    elseif jit.os ~= "OSX" and jit.arch ~= "x64" then
        expected = 8
    end
    test.eq(status, expected, ran)
    test.eq((ran:gsub("\r", "")), jit.os .. "\n" .. jit.arch)
end

-- An `and` whose left side the target settles leaves the right side
-- unlowered; a left side decided at run time still runs.
function M.aSettledTargetTestSkipsItsRightSide()
    local source = [[
cdef function probe(): boolean
cdef function windowsOnly(): boolean

local function main(): int32
    if jit.os == "Windows" and windowsOnly() then
        return 1
    end
    if probe() or jit.os == "Windows" then
        return 2
    end
    return 0
end
]]
    local linux = assert(lower(source, "x86_64-unknown-linux-gnu"))
    test.eq(calls(linux, "windowsOnly"), false)
    test.eq(calls(linux, "probe"), true)
    local windows = assert(lower(source, "x86_64-pc-windows-msvc"))
    test.eq(calls(windows, "windowsOnly"), true)
    test.eq(calls(windows, "probe"), true)
end

function M.aTargetComparedWithAnythingButALiteralIsRefused()
    local ir, message = lower([[
local function main(argc: int32, argv: cstring*): int32
    @unsafe do
        if jit.os == argv[0] then
            return 1
        end
    end
    return 0
end
]], "x86_64-unknown-linux-gnu")
    test.eq(ir, nil)
    assert(message:find("jit.os and jit.arch are compared only with a string literal", 1, true), message)
end

function M.onlyTheTargetIsReadFromJit()
    local ir, message = lower([[
local function main(): int32
    if jit.version == "LuaJIT" then
        return 1
    end
    return 0
end
]], "x86_64-unknown-linux-gnu")
    test.eq(ir, nil)
    assert(message:find("a native program reads only jit.os and jit.arch", 1, true), message)
end

return M
