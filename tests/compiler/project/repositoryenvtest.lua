-- The environment the Nupp-suite loader roots at a project (#451).
--
-- A manifest that includes the standard library's own source -- this repository
-- includes `src` -- checks against the carried copy instead, so suites share the
-- checked standard-library modules. Every other include is the project's own and
-- stays, which is what keeps the loader usable in a consumer project: its `src` is
-- its code, not a second standard library.
local test = require("assert")
local fs = require("nupp.compiler.fs")
local repositoryenv = require("nupp.compiler.project.repositoryenv")

local ROOT = require("helpers.paths").tests .. "/.."

local M = {}

local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

local function tempProject(manifest)
    local dir = os.tmpname()
    os.remove(dir)
    assert(fs.mkdir(dir .. "/src/bytes"))
    if manifest then
        write(dir .. "/nupp.lua", manifest)
    end
    write(dir .. "/src/main.nupp", "return true\n")
    -- One carried module's source is not the carried library.
    write(dir .. "/src/bytes/init.nupp", "return {}\n")

    return dir
end

local function remove(dir)
    os.execute("rm -rf " .. string.format("%q", dir))
end

function M.theRepositoryManifestLeavesOutTheCarriedLibrarySource()
    test(repositoryenv.holdsCarriedLibrary(ROOT .. "/src"), "src does not hold the carried library")
    local config = repositoryenv.config(ROOT)
    test.deepeq(config.include, {"tests/tools/test/runner", "evals/lib"})
    test(config.build ~= nil, "the rest of the manifest is kept")
end

function M.eachConfigIsAFreshTable()
    local first = repositoryenv.config(ROOT)
    first.include[#first.include + 1] = "changed"
    first.changed = true
    local second = repositoryenv.config(ROOT)
    test.eq(second.changed, nil)
    test.deepeq(second.include, {"tests/tools/test/runner", "evals/lib"})
end

function M.aConsumerProjectKeepsItsOwnSource()
    local dir = tempProject('return {include = {"src"}, build = {entries = {"main"}}}\n')
    local ok, err = pcall(function()
        test(not repositoryenv.holdsCarriedLibrary(dir .. "/src"), "a partial library counted as the carried one")
        local config = repositoryenv.config(dir)
        test.deepeq(config.include, {"src"})
        test.deepeq(config.build.entries, {"main"})
    end)
    remove(dir)
    assert(ok, err)
end

function M.aManifestWithoutIncludesIsReadUnchanged()
    local dir = tempProject('return {build = {entries = {"main"}}}\n')
    local bare = tempProject(nil)
    local ok, err = pcall(function()
        local config = repositoryenv.config(dir)
        test.eq(config.include, nil)
        test.deepeq(config.build.entries, {"main"})
        test.eq(next(repositoryenv.config(bare)), nil, "a folder with no manifest has no config")
    end)
    remove(dir)
    remove(bare)
    assert(ok, err)
end

function M.anEnvironmentTakesTheFilteredManifest()
    local env = repositoryenv.new(ROOT, {cache = false, config = {include = {"src"}}})
    test.eq(env.rootDir, ROOT)
    test.deepeq(env.config.include, {"tests/tools/test/runner", "evals/lib"})
end

return M
