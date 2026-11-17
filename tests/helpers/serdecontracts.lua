-- The serde contracts' native-build project, built ahead of time.
--
-- Its `compiled-contracts` target compiles the serde runtime and fixtures with
-- `aot = "require"`, which on Linux CI took most of serdecontracttest's 191 s
-- and was charged to the one case that asked for it (#383). The runner starts it
-- in the background when the run begins (the `prerequisites` in tests/groups.lua)
-- and deals serdecontracttest last, so the build overlaps other suites instead of
-- holding up the run or a case. Run without that runner, `path` builds it itself;
-- the build is incremental, so a second one answers from its cache.

local prerequisite = require("helpers.prerequisite")

local M = {}

M.PROJECT = "bench/serde-spike/contracts/native-build"
M.TARGET = "compiled-contracts"

--- Where the runner leaves the path of the project it built for this run, or
--- the result of the build it started in the background.
M.variable = "NUPP_TEST_SERDE_CONTRACTS"
M.pending = "NUPP_TEST_SERDE_CONTRACTS_PENDING"

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- The shell command that builds the target from ROOT and prints the project's
--- absolute path last.
function M.command(root)
    return table.concat({
        "cd " .. quote(root .. "/" .. M.PROJECT),
        "../../../../bin/nupp build --target " .. M.TARGET,
        "(pwd -W 2>/dev/null || pwd)",
    }, " && ")
end

local cached, problem

--- The built project's directory, or nil and the build's output.
function M.path(root)
    if not cached and not problem then
        local status, output, path = prerequisite.result(M, root)
        if status ~= 0 or not path then
            problem = ("`nupp build --target %s` failed:\n%s"):format(M.TARGET, output:sub(-2000))
        else
            cached = path
        end
    end

    return cached, problem
end

return M
