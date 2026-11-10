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

    return status, (output:gsub("\r?\n__status__:%d+%s*$", ""))
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
cdef function luaL_openlibs(L: voidptr): nil
cdef function luaL_loadstring(L: voidptr, source: cstring): int32
cdef function lua_pcall(L: voidptr, nargs: int32, nresults: int32, handler: int32): int32
cdef function lua_pushcclosure(L: voidptr, fn: function(L: voidptr): int32, n: int32): nil
cdef function lua_pushinteger(L: voidptr, n: int64): nil
cdef function lua_pushstring(L: voidptr, s: cstring): nil
cdef function lua_setfield(L: voidptr, index: int32, k: cstring): nil
cdef function lua_tointeger(L: voidptr, index: int32): int64
cdef function lua_tolstring(L: voidptr, index: int32, length: voidptr): cstring
cdef function lua_close(L: voidptr): nil
cdef function puts(s: cstring): int32

const GLOBALS = -10002
]]

-- `main` creates a LuaJIT state, registers a Nupp function as a C callback,
-- runs a chunk under `lua_pcall`, and exits with what the chunk returned.
local HOST = LUA_API .. [[

local function answer(L: voidptr): int32
    lua_pushinteger(L, 42)
    return 1
end

--- The sum of 1..n with every multiple of 3 skipped, by loop and branch.
local function tally(n: int32): int32
    local total: int32 = 0
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
    lua_pushinteger(L, tally(10))
    lua_setfield(L, GLOBALS, "tally")
    if argc > 1 then
        lua_pushstring(L, argv[1])
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
        return 100 + status
    end
    local result = lua_tointeger(L, -1) as int32
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

function M.aNuppCallbackRaisingAnErrorReachesProtectedCall()
    requireCodegen()
    local executable, output = link(LUA_API .. [[

cdef function luaL_error(L: voidptr, format: cstring, ...): int32

local function fail(L: voidptr): int32
    return luaL_error(L, "failed with %d", 7)
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

function M.integerArithmeticFloorsAsTheLanguageDoes()
    requireCodegen()
    local executable, output = link([[
local function check(ok: boolean, code: int32): int32
    if ok then
        return 0
    end
    return code
end

local function main(): int32
    local a: int32 = -7
    local b: int32 = 2
    local failed = check(a // b == -4, 1) + check(a % b == 1, 2) + check(a / b == -3.5, 3)
    local wide: int64 = 3000000000
    failed += check(wide * 2 == 6000000000, 4)
    local x: number = 7.5
    failed += check(x // 2 == 3, 5) + check(x % 2 == 1.5, 6)
    local bits: uint32 = 0xF0
    failed += check((bits >> 4) == 15 and (bits & 0x30) == 0x30, 7)
    local count: int32 = 0
    while true do
        count += 1
        if count >= 5 then
            break
        end
    end
    failed += check(count == 5, 8)
    return failed
end
]])
    assert(executable ~= nil, output)
    local status, ran = run(quote(executable))
    test.eq(status, 0, ran)
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
