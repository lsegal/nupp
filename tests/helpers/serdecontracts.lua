-- The serde contracts' native-build project, built ahead of time.
--
-- Its `compiled-contracts` target compiles the serde runtime and fixtures with
-- `aot = "require"`, which on Linux CI took most of serdecontracttest's 191 s
-- and was charged to the one case that asked for it (#383). The runner builds it
-- before any case starts (the `prerequisites` in tests/groups.lua) and names the
-- project in `variable`. Run without that runner, `path` builds it itself; the
-- build is incremental, so a second one answers from its cache.

local M = {}

M.PROJECT = "bench/serde-spike/contracts/native-build"
M.TARGET = "compiled-contracts"

--- Where the runner leaves the path of the project it built for this run.
M.variable = "NUPP_TEST_SERDE_CONTRACTS"

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
    if cached or problem then
        return cached, problem
    end
    local prepared = os.getenv(M.variable)
    if prepared and prepared ~= "" then
        cached = prepared
        return cached
    end
    local pipe = assert(io.popen(M.command(root) .. " 2>&1; printf '\n__status__:%s' $?"))
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__status__:(%d+)%s*$"))
    output = output:gsub("\n__status__:%d+%s*$", "")
    if status ~= 0 then
        problem = ("`nupp build --target %s` failed:\n%s"):format(M.TARGET, output:sub(-2000))
        return nil, problem
    end
    cached = assert(output:match("([^\r\n]+)%s*$"), "the build named no project")

    return cached
end

return M
