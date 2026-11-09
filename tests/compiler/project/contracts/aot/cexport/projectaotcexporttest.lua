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
    printf("%d %.1f %.1f\n", (int)game_add(2, 3), game_scale(4, 1.5f, true), game_scale(4, 1.5f, false));
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
    local code, text = process.capture(
        {nupp, "export-c", "-o", "game.h", "src/main.nupp", "main.add", "main.scale"},
        {cwd = dir}
    )
    testAssert.eq(code, 0, text)
    assert(exists(dir .. "/game.h"), "export-c writes the header: " .. text)

    return dir
end

local function run(dir, program)
    local code, text = process.capture({program})
    testAssert.eq(code, 0, text)
    testAssert.eq(text:match("[^\r\n]+"), "5 7.5 4.0", "C reaches every exported function through the header")
    remove(dir)
end

--- A C program includes the generated header, links the static archive and
--- calls the exported functions by their C names.
function M.cCallsAotExportsFromTheStaticArchive()
    local dir = library("static")
    local archive = dir .. "/out/lib/libdefault_aot.a"
    assert(exists(archive), "the static library is the target's AOT archive")
    local program = dir .. "/main" .. (jit.os == "Windows" and ".exe" or "")
    local command = ("cd '%s' && %s -std=c11 -o '%s' main.c '%s'%s"):format(
        dir,
        compiler(),
        program,
        archive,
        jit.os == "Windows" and "" or " -lm"
    )
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
        command = ("cd '%s' && %s -std=c11 -o '%s' main.c -L'%s' -ldefault_aot -Wl,-rpath,'%s'"):format(
            dir,
            compiler(),
            program,
            lib,
            lib
        )
    end
    testAssert.eq(os.execute(command), 0, command)
    run(dir, program)
end

return M
