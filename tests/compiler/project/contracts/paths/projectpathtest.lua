local fixture = require("helpers.projectfixture")
local testAssert = fixture.testAssert
local process = fixture.process
local fs = fixture.fs
local compilerEnv = fixture.compilerEnv

local M = {}

function M.windowsMkdirUsesNativePathAndIsIdempotent()
    testAssert.eq(fs.join("C:/one", "D:/two"), "D:/two", "joining an absolute Windows path does not prefix it")
    local command = process.mkdirCommand("build/nupp", true)
    testAssert.eq(table.concat(command, " "), "cmd /d /c if not exist build\\nupp mkdir build\\nupp")

    local posix = process.mkdirCommand("build/nupp", false)
    testAssert.eq(table.concat(posix, " "), "mkdir -p build/nupp")
end

-- msvcrt's `tmpnam` names a file at the drive root, which an ordinary user
-- cannot write, so every capture through it came back empty with "Access is
-- denied." and no native facility could be built.
function M.windowsTempNamesAtTheDriveRootMoveUnderTemp()
    local temp = "C:\\Users\\me\\AppData\\Local\\Temp"
    testAssert.eq(process.windowsTempName("\\s1c4.", temp), temp .. "\\s1c4")
    testAssert.eq(process.windowsTempName("\\s1c4.2", temp .. "\\"), temp .. "\\s1c4.2")
    testAssert.eq(process.windowsTempName("C:\\s1c4.", temp), temp .. "\\s1c4")
    testAssert.eq(process.windowsTempName("/s1c4.", temp), temp .. "\\s1c4")
    testAssert.eq(
        process.windowsTempName(temp .. "\\lua_x", temp),
        temp .. "\\lua_x",
        "a name already under a directory is kept"
    )
    testAssert.eq(process.windowsTempName("/c/Users/me/x", temp), "/c/Users/me/x", "an MSYS path is kept")
    testAssert.eq(process.windowsTempName("\\s1c4.", nil), "\\s1c4.", "no temporary directory keeps the name")
    testAssert.eq(process.windowsTempName("\\s1c4.", ""), "\\s1c4.")
    assert(type(process.tmpname()) == "string")
end

function M.windowsAbsolutePathsAreNotModulesUnderTheCurrentRoot()
    local path = "C:/Users/runner/AppData/Local/Temp/backend/source/example.nupp"
    testAssert.eq(
        compilerEnv.moduleNameInRoots({"."}, path),
        nil,
        "a drive path outside the project has no canonical module name"
    )
    assert(
        not compilerEnv.isProjectPath({roots = {"."}, config = {}, rootDir = "."}, path),
        "a drive path outside the project is not project source"
    )
    testAssert.eq(
        compilerEnv.moduleNameInRoots({"."}, "source/example.nupp"),
        "source.example",
        "a relative path remains a module beneath the current root"
    )
end

-- A relative path that climbs out of its root with `..` was named as if it were
-- beneath it: `../mini.nupp` against "." became the module "...mini", which
-- import-c then wrote as the generated module's name. A `..` that stays inside
-- keeps the name its spelling always had, because a source loaded through that
-- spelling is already known by it.
function M.aPathThatClimbsOutOfItsRootIsNotAModuleBeneathIt()
    for _, case in ipairs({
        {".", "../mini.nupp"},
        {"src", "src/../mini.nupp"},
        {"src", "src/a/../../b.nupp"},
        {"/work/p", "/work/p/../q/c.nupp"},
    }) do
        testAssert.eq(compilerEnv.moduleNameInRoots({case[1]}, case[2]), nil, case[2])
        assert(
            not compilerEnv.isProjectPath({roots = {case[1]}, config = {}, rootDir = "."}, case[2]),
            case[2] .. " is not project source"
        )
    end
    testAssert.eq(compilerEnv.moduleNameInRoots({"src"}, "src/a/b.nupp"), "a.b")
    testAssert.eq(
        compilerEnv.moduleNameInRoots({"."}, "tests/../src/a.nupp"),
        "tests....src.a",
        "a .. that stays inside keeps its spelling"
    )
    assert(compilerEnv.isProjectPath({roots = {"."}, config = {}, rootDir = "."}, "tests/../src/a.nupp"))
end

return M
