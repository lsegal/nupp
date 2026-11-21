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
-- Without `src` a fragment sees the standard library a project outside this
-- repository sees, built from the same bytes. What only `src` holds -- modules the
-- compiler does not carry, such as `debug.bench` -- is not reachable, so a suite
-- that checks against those keeps a plain environment: the guide examples do.
--
-- The compiler owns the rule (#451), because the Nupp-suite loader in `tests/run.lua`
-- needs it in every project; this rooting at the repository is all that is left here.
local repositoryenv = require("nupp.compiler.project.repositoryenv")

local ROOT = require("helpers.paths").tests .. "/.."

--- The repository's manifest without its `src` include. A fresh table each time,
--- as an environment reading the manifest itself would get.
local function config()
    return repositoryenv.config(ROOT)
end

--- An environment rooted at the repository; `opts` as `envMod.new` takes them.
local function new(opts)
    return repositoryenv.new(ROOT, opts)
end

return {root = ROOT, config = config, new = new}
