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
    local reference
    status, reference = run(
        ("cd %s && LUA_PATH=%s luajit -joff host.lua"):format(quote(dir), quote(HERE .. "/../build/?.lua;;"))
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

-- What lowering refuses is reported where it was written, before anything is
-- compiled, so this needs no code generator.
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
