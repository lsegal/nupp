local fixture = require("helpers.projectfixture")
local testAssert = fixture.testAssert
local project = fixture.project
local process = fixture.process
local write = fixture.write
local exists = fixture.exists
local tempProject = fixture.tempProject
local remove = fixture.remove
local libraryName = fixture.libraryName

local M = {}

local SOURCE = [[
@aot(export = "game_add")
local function add(a: int32, b: int32): int32
   return a + b
end

@aot(export = "game_scale")
local function scale(value: integer, by: float, enabled: boolean): number
   if enabled then
      return value * by
   end
   return value
end

return {add = add, scale = scale}
]]

local PROGRAM = [[
#include <stdio.h>
#include "game.h"

int main(void) {
    printf("%d %.1f %.1f\n", (int)game_add(2, 3), game_scale(5, 1.5f, true), game_scale(5, 1.5f, false));
    return 0;
}
]]

local function compiler()
    return os.getenv("NUPP_CC") or (jit.os == "Windows" and "gcc" or "cc")
end

--- A library project: its `@aot(export)` functions, built into the target's
--- AOT library, and the header `export-c` declares them in.
local function library(linkage)
    local dir = tempProject({["src/main.nupp"] = SOURCE, ["main.c"] = PROGRAM})
    write(
        dir .. "/nupp.lua",
        (
            [=[return {include = {"src"}, build = {kind = "component",
      aot = "require", aotLinkage = %q, outDir = %q,
      output = %q, entries = {"main"}}}]=]
        ):format(linkage, dir .. "/out", dir .. "/out/component.lua")
    )
    testAssert.eq(project.build(dir), 0)
    local nupp = require("helpers.paths").root .. "/bin/nupp"
    local code, text = process.capture({nupp, "export-c", "-o", "game.h", "src/main.nupp", "main.add", "main.scale"}, {
        cwd = dir
    })
    testAssert.eq(code, 0, text)
    assert(exists(dir .. "/game.h"), "export-c writes the header: " .. text)

    return dir
end

local function run(dir, program)
    local code, text = process.capture({program})
    testAssert.eq(code, 0, text)
    testAssert.eq(text:match("[^\r\n]+"), "5 7.5 5.0", "C reaches every exported function through the header")
    remove(dir)
end

--- A C program includes the generated header, links the static archive and
--- calls the exported functions by their C names.
function M.cCallsAotExportsFromTheStaticArchive()
    local dir = library("static")
    local archive = dir .. "/out/lib/libdefault_aot.a"
    assert(exists(archive), "the static library is the target's AOT archive")
    local program = dir .. "/main" .. (jit.os == "Windows" and ".exe" or "")
    local command = (
        "cd '%s' && %s -std=c11 -o '%s' main.c '%s'%s"
    ):format(dir, compiler(), program, archive, jit.os == "Windows" and "" or " -lm")
    testAssert.eq(os.execute(command), 0, command)
    run(dir, program)
end

--- The same functions, from the shared library: a C program links it and
--- the loader resolves the exports. On Windows the DLL loads into a process
--- that carries no Lua at all.
function M.cCallsAotExportsFromTheSharedLibrary()
    local dir = library("shared")
    local lib = dir .. "/out/lib"
    local shared = lib .. "/" .. libraryName("default_aot")
    assert(exists(shared), "the shared library is the target's AOT library")
    local command
    local program
    if jit.os == "Windows" then
        -- Beside the DLL, which is where Windows looks first.
        program = lib .. "/main.exe"
        command = ("cd '%s' && %s -std=c11 -o '%s' main.c '%s'"):format(dir, compiler(), program, shared)
    else
        program = dir .. "/main"
        command = (
            "cd '%s' && %s -std=c11 -o '%s' main.c -L'%s' -ldefault_aot -Wl,-rpath,'%s'"
        ):format(dir, compiler(), program, lib, lib)
    end
    testAssert.eq(os.execute(command), 0, command)
    run(dir, program)
end

--- The names `shared`'s export table publishes, as the platform's own tools
--- read it: `nm -D` on ELF, `nm -gU` on Mach-O and `objdump -p` on PE.
local function exported(shared)
    local command
    if jit.os == "Windows" then
        command = ("objdump -p '%s'"):format(shared)
    elseif jit.os == "OSX" then
        command = ("nm -gU '%s'"):format(shared)
    else
        command = ("nm -D --defined-only '%s'"):format(shared)
    end
    local pipe = assert(io.popen(command .. " 2>&1"))
    local text = pipe:read("*a")
    pipe:close()
    local names = {}
    if jit.os == "Windows" then
        local listing = text:match("%[Ordinal/Name Pointer%] Table\r?\n(.-)\r?\n\r?\n")
        assert(listing ~= nil, command .. " lists no export table:\n" .. text)
        for name in listing:gmatch("%]%s+([%w_%.%$@]+)") do
            names[name] = true
        end
    else
        for line in text:gmatch("[^\r\n]+") do
            local name = line:match("%s[A-Za-z]%s+(%S+)$")
            if name ~= nil then
                names[jit.os == "OSX" and name:gsub("^_", "") or name] = true
            end
        end
    end

    return names, text
end

--- A shared library publishes its C names and the `ks_` symbols its Lua
--- wrappers resolve, and nothing else: not the Windows binding's Lua API jump
--- stubs, its entry point or its stack probe.
function M.theSharedLibraryPublishesOnlyItsCNamesAndWrapperSymbols()
    local dir = library("shared")
    local shared = dir .. "/out/lib/" .. libraryName("default_aot")
    local names, text = exported(shared)
    assert(names.game_add and names.game_scale, "the C names are published:\n" .. text)
    for name in pairs(names) do
        assert(
            name == "game_add" or name == "game_scale" or name:sub(1, 3) == "ks_",
            name .. " is published, which neither C nor a Lua wrapper resolves:\n" .. text
        )
    end
    for _, internal in ipairs({"ks_dll_main", "lua_gettop", "___chkstk_ms", "ks_lua_slot_lua_gettop"}) do
        assert(not names[internal], internal .. " is internal to the library:\n" .. text)
    end
    remove(dir)
end

--- The link publishes what it is told to and hides every other global
--- definition, which a linker given no list would publish too.
function M.theLinkHidesAGlobalDefinitionItsListLeavesOut()
    local aotllvm = require("nupp.tools.build.aotllvm")
    local suffix = jit.os == "Windows" and ".dll" or jit.os == "OSX" and ".dylib" or ".so"
    local triple = assert(require("nupp.compiler.aot.target").hostTriple())
    local dir = tempProject({})
    local ir = dir .. "/unit.ll"
    write(ir, "define i32 @listed_entry() {\n  ret i32 1\n}\n\ndefine i32 @ks_internal_helper() {\n  ret i32 2\n}\n")
    local object = dir .. "/unit.o"
    local compileErr = aotllvm.compileMany({{ir = ir, triple = triple, tier = "baseline", object = object}})
    assert(compileErr == nil, compileErr)
    local shared = dir .. "/listed" .. suffix
    local linkErr = aotllvm.link(triple, {object}, shared, dir, {"listed_entry"})
    assert(linkErr == nil, linkErr)
    local names, text = exported(shared)
    assert(names.listed_entry, "the listed entry is published:\n" .. text)
    assert(not names.ks_internal_helper, "a global definition the list leaves out is hidden:\n" .. text)
    remove(dir)
end

return M
