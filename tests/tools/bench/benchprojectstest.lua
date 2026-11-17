-- Every benchmark project under `bench/` still checks against the tree it sits in.
--
-- A benchmark project includes `../../src`, so a library change reaches it the way it
-- reaches any caller, and nothing else checks most of them: the SIMD conformance rows
-- build narrow entries of a few, and the rest are run by hand when someone measures.
-- `bench/serde-spike` gathered eighteen "Buffer is not a Buffer" errors that way when
-- the JSON writer moved to `nupp.text` buffers, and `bench/simd-json` two more, with
-- no suite noticing either.
--
-- A project whose sources a script prepares first (`prepare.sh`) is skipped: until
-- the script runs it names an entry that does not exist yet, and the conformance row
-- that runs the script already checks what it builds. So is one whose native
-- packages (`pkgConfig`) this machine's pkg-config cannot resolve: checking it reads
-- their flags, and CI's runners carry neither simdjson nor a luajit.pc.
--
-- Each project is its own case, checking the sources under its own include roots:
-- `../../src` is the repository's project, which `nupp check` at the root covers, and
-- naming it here checked the whole compiler again for every benchmark, cold, about a
-- thousand seconds in all (#360). The tree still reaches each project through its
-- imports, which is what a library change breaks.

local HERE = require("helpers.paths").absoluteTests
if HERE:sub(1, 1) ~= "/" and not HERE:match("^%a:[/\\]") then
    local pipe = assert(io.popen("pwd"))
    HERE = assert(pipe:read("*l")) .. "/" .. HERE
    pipe:close()
end
local ROOT = assert(HERE:match("^(.*)/[^/]+$"), "tests directory has no parent")
local NUPP = ROOT .. "/bin/nupp"
local envMod = require("nupp.compiler.project.env")
local manifest = require("nupp.tools.build.manifest")

local M = {}

local function exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
    end

    return file ~= nil
end

local function read(path)
    local file = io.open(path, "rb")
    if not file then
        return ""
    end
    local content = file:read("*a")
    file:close()

    return content
end

--- Whether pkg-config resolves every package a manifest names under `pkgConfig`.
local function nativePackagesResolve(manifest)
    local packages = {}
    for value in manifest:gmatch("pkgConfig%s*=%s*(%b{})") do
        for name in value:gmatch('"([^"]+)"') do
            packages[#packages + 1] = name
        end
    end
    for value in manifest:gmatch('pkgConfig%s*=%s*"([^"]*)"') do
        for name in value:gmatch("%S+") do
            packages[#packages + 1] = name
        end
    end
    if #packages == 0 then
        return true
    end
    local status = os.execute("pkg-config --exists " .. table.concat(packages, " ") .. " >/dev/null 2>&1")

    return status == 0 or status == true
end

local function projects()
    local pipe = assert(io.popen("cd '" .. ROOT .. "/bench' && ls -d */"))
    local names = {}
    for line in pipe:lines() do
        local name = line:gsub("/$", "")
        local dir = ROOT .. "/bench/" .. name
        if exists(dir .. "/nupp.lua")
            and not exists(dir .. "/prepare.sh")
            and nativePackagesResolve(read(dir .. "/nupp.lua"))
        then
            names[#names + 1] = name
        end
    end
    pipe:close()
    table.sort(names)

    return names
end

--- Whether a manifest include root lies inside its project rather than reaching out.
local function ownRoot(dir)
    return dir:sub(1, 1) ~= "/" and not dir:match("^%a:[/\\]") and dir ~= ".." and dir:sub(1, 3) ~= "../"
end

--- The project's own sources: those under the include roots inside it.
local function ownSources(dir)
    local config = assert(manifest.load(dir))
    local roots = {}
    for _, include in ipairs(config.include or {}) do
        if ownRoot(include) then
            roots[#roots + 1] = include
        end
    end
    assert(
        #roots > 0 or #(config.include or {}) == 0,
        ("bench project %s includes nothing of its own"):format(dir)
    )
    local outDir = dir .. "/" .. (config.build and config.build.outDir or "build")
    local sources = envMod.listSourceFilesFor({}, dir, roots, outDir, true)
    table.sort(sources)

    return sources
end

local function checkProject(name)
    local dir = ROOT .. "/bench/" .. name
    local sources = ownSources(dir)
    assert(#sources > 0, ("bench/%s has no sources of its own"):format(name))
    local quoted = {}
    for index, path in ipairs(sources) do
        quoted[index] = "'" .. path .. "'"
    end
    local log = os.tmpname()
    local status = os.execute(
        ("cd '%s' && NO_COLOR=1 '%s' check %s >'%s' 2>&1"):format(dir, NUPP, table.concat(quoted, " "), log)
    )
    local output = read(log)
    os.remove(log)
    assert(status == 0 or status == true, ("bench/%s does not check:\n%s"):format(name, output))
end

function M.theBenchmarkProjectsAreFound()
    local names = projects()
    assert(#names >= 8, "the benchmark projects were found: " .. #names)
end

for _, name in ipairs(projects()) do
    M["benchmarkProjectChecks_" .. name:gsub("%W", "_")] = function()
        checkProject(name)
    end
end

return M
