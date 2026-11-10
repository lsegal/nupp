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
local span = require("bytes.span")

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

-- A map kernel: the guard relates its spans, so they share one count.
@aot(export = "game_saxpy")
local function saxpy(exclusive out: span.WriteSpan<number>, borrows xs: span.Span<number>, a: number): nil
   assert(#out == #xs, "length mismatch")
   for i = 1, #out do
      out[i] = a * xs[i]
   end
end

-- A block kernel: each span has its own count, and several results come
-- back through a struct.
@aot(export = "game_bounds")
local function bounds(borrows values: span.Span<number>, borrows weights: span.Span<float>): (number, number, boolean)
   local low = 1e300
   local high = -1e300
   for i = 1, #values do
      local value = values[i]
      if value < low then
         low = value
      end
      if value > high then
         high = value
      end
   end
   return low, high, #weights == #values
end

return {add = add, scale = scale, saxpy = saxpy, bounds = bounds}
]]

local PROGRAM = [[
#include <stdio.h>
#include "game.h"

int main(void) {
    double xs[3] = {1.0, 3.0, 2.0};
    double out[3] = {0.0, 0.0, 0.0};
    float weights[2] = {1.0f, 2.0f};
    game_bounds_result bounds;
    game_saxpy(out, xs, 2.0, 3);
    game_bounds(xs, weights, 3, 2, &bounds);
    printf("%d %.1f %.1f\n", (int)game_add(2, 3), game_scale(5, 1.5f, true), game_scale(5, 1.5f, false));
    printf("%.1f %.1f %.1f\n", out[0], out[1], out[2]);
    printf("%.1f %.1f %d\n", bounds.r1, bounds.r2, (int)bounds.r3);
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
        {nupp, "export-c", "-o", "game.h", "src/main.nupp", "main.add", "main.scale", "main.saxpy", "main.bounds"},
        {cwd = dir}
    )
    testAssert.eq(code, 0, text)
    assert(exists(dir .. "/game.h"), "export-c writes the header: " .. text)

    return dir
end

local function run(dir, program)
    local code, text = process.capture({program})
    testAssert.eq(code, 0, text)
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    testAssert.eq(lines[1], "5 7.5 5.0", "C reaches every scalar export through the header")
    testAssert.eq(lines[2], "2.0 6.0 4.0", "C passes arrays to a span export and their shared count")
    testAssert.eq(lines[3], "1.0 3.0 0", "C reads several results through the declared struct")
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

return M
