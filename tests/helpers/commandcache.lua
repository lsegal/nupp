-- The store the compiler commands a run's cases start share (`NUPP_CACHE_DIR`).
--
-- Its entries -- the prelude, the standard-library interfaces, objects -- are
-- keyed by what they were computed from and stamped with the compiler that
-- computed them, so two temporary projects only hit each other's entries when
-- the answer is the same answer. A store made per suite run started cold in
-- every slice of a sliced suite, and the first native build of each slice paid
-- to check and generate `simd` and the rest of the standard library again:
-- more than half of a ten-second build, two dozen times a suite (#406).
--
-- One directory for the whole run instead: the one the runner names for the
-- commands cases start when it names one, and otherwise the sibling its lanes'
-- own stores sit beside. Writes to a store are atomic, so two lanes writing it
-- at once can lose an entry, which is a recomputation later, and never a wrong
-- answer. Outside a runner lane it is a temporary directory of this process.
local fs = require("nupp.compiler.fs")

local M = {}

local memo = nil

local function runStore()
    local named = rawget(_G, "__NUPP_TEST_COMMAND_CACHE")
    if type(named) == "string" and named ~= "" then
        return named
    end
    local lane = rawget(_G, "__NUPP_TEST_LANE_CACHE")
    local root = type(lane) == "string" and lane:match("^(.*)[/\\]shard%-%d+$")
    if root then
        return root .. "/commands"
    end

    return nil
end

--- The absolute directory, created on first use.
function M.dir()
    if memo then
        return memo
    end
    local dir = runStore()
    if not dir then
        dir = os.tmpname()
        os.remove(dir)
    end
    dir = fs.absolute(dir)
    assert(os.execute(("mkdir -p %q"):format(dir)) == 0, "cannot create the command store " .. dir)
    memo = dir

    return dir
end

return M
