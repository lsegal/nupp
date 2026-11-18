-- Environments rooted at the repository that check against the standard library
-- the compiler carries.
--
-- The repository's manifest includes `src`, which holds the standard library's own
-- source. Rooted there, every standard-library module a fragment reaches resolves
-- to a file under `src` -- a project module -- instead of the carried copy, so
-- neither the process-wide sharing of checked standard-library modules (#395) nor
-- the standard-library store applies, and every such environment checked the same
-- forty-odd modules again: 10 to 30 seconds for the first check of each (#410).
--
-- Those files are the bytes the running compiler was built from, so leaving `src`
-- out changes no answer for a fragment checked inside the repository. A suite about
-- the repository's own sources, rather than a fragment checked beside them, still
-- roots a plain environment.
local envMod = require("nupp.compiler.project.env")

local ROOT = require("helpers.paths").tests .. "/.."

--- The repository's manifest without its `src` include. A fresh table each time,
--- as an environment reading the manifest itself would get.
local function config()
    local manifest = {}
    for key, value in pairs(assert(loadfile(ROOT .. "/nupp.lua"))()) do
        manifest[key] = value
    end
    local include = {}
    for _, dir in ipairs(manifest.include or {}) do
        if dir ~= "src" then
            include[#include + 1] = dir
        end
    end
    manifest.include = include

    return manifest
end

--- An environment rooted at the repository; `opts` as `envMod.new` takes them.
local function new(opts)
    local merged = {}
    for key, value in pairs(opts or {}) do
        merged[key] = value
    end
    merged.config = config()

    return envMod.new(ROOT, merged)
end

return {root = ROOT, config = config, new = new}
