-- What an AOT shared library publishes, and how each linker is told so.
local profile = require("nupp.compiler.aot.llvm.profile")

local M = {}

local function target(triple)
    return assert(profile.of(triple))
end

local function has(argv, value)
    for _, argument in ipairs(argv) do
        if argument == value then
            return true
        end
    end

    return false
end

local IR = [[
define internal double @nupp.mod(double %a, double %b) #0 {
define private i32 @helper_private() {
define hidden void @ks_0123_native_only__baseline(ptr %p, i64 %count) #1 {
define void @ks_0123_scale__baseline(ptr noalias %p_values, i64 range(i64 0, 9007199254740993) %count) #1 {
define { double, double } @ks_0123_pair__avx2(double %p_a) #1 {
define i64 @ks_0123_scale__baseline_layout_Point_size() #2 {
define i32 @ks_aot_feature_tier() #3 {
define dso_local i32 @ks_0123_build__baseline(ptr %L) #4 {
@game_add = alias i32 (i32, i32), ptr @ks_0123_add__baseline
@game_hidden = hidden alias i32 (i32, i32), ptr @ks_0123_add__baseline
@ks_constant = private unnamed_addr constant [4 x i8] c"abc\00"
declare double @sin(double)
]]

function M.publicSymbolsAreTheDefinitionsNothingKeepsLocal()
    local names = profile.publicSymbols(IR)
    local expected = {
        "ks_0123_scale__baseline",
        "ks_0123_pair__avx2",
        "ks_0123_scale__baseline_layout_Point_size",
        "ks_aot_feature_tier",
        "ks_0123_build__baseline",
        "game_add",
    }
    assert(#names == #expected, "published: " .. table.concat(names, ", "))
    for position, name in ipairs(expected) do
        assert(names[position] == name, ("expected %s at %d, got %s"):format(name, position, tostring(names[position])))
    end
end

function M.anElfLibraryPublishesItsListThroughAVersionScript()
    local elf = target("x86_64-unknown-linux-gnu")
    local list = profile.exportList(elf, {"game_add", "ks_b", "game_add"})
    assert(list == "{\n  global:\n    game_add;\n    ks_b;\n  local:\n    *;\n};\n", list)
    local argv = profile.sharedLink(elf, "out.so", {"a.o"}, "out.so", nil, "out.exports")
    assert(has(argv, "--version-script=out.exports"), table.concat(argv, " "))
end

function M.anElfLibraryWithNothingToPublishHidesEverything()
    local list = profile.exportList(target("x86_64-unknown-linux-gnu"), {})
    assert(list == "{\n  local:\n    *;\n};\n", list)
end

function M.aMachOLibraryPublishesItsListAsExportedSymbols()
    local macho = target("aarch64-apple-darwin")
    local list = profile.exportList(macho, {"ks_b", "game_add"})
    assert(list == "_game_add\n_ks_b\n", list)
    local argv = profile.sharedLink(macho, "out.dylib", {"a.o"}, "out.dylib", nil, "out.exports")
    for position, argument in ipairs(argv) do
        if argument == "-exported_symbols_list" then
            assert(argv[position + 1] == "out.exports", table.concat(argv, " "))

            return
        end
    end
    error("no exported-symbols list: " .. table.concat(argv, " "))
end

function M.aWindowsLibraryPublishesItsListThroughAModuleDefinition()
    local coff = target("x86_64-pc-windows-msvc")
    local list = profile.exportList(coff, {"ks_b", "game_add"})
    assert(list == "EXPORTS\n    game_add\n    ks_b\n", list)
    local argv = profile.sharedLink(coff, "out.dll", {"a.o"}, "out.dll", nil, "out.exports")
    assert(has(argv, "/def:out.exports"), table.concat(argv, " "))
end

function M.aLinkWithoutAListStatesNone()
    for _, triple in ipairs({"x86_64-unknown-linux-gnu", "aarch64-apple-darwin", "x86_64-pc-windows-msvc"}) do
        local argv = table.concat(profile.sharedLink(target(triple), "out", {"a.o"}, "out"), " ")
        assert(not argv:find("version-script", 1, true), argv)
        assert(not argv:find("exported_symbols_list", 1, true), argv)
        assert(not argv:find("/def:", 1, true), argv)
    end
end

return M
