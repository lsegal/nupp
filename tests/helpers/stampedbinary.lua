-- The stamped compiler binary hostbinarytest mistreats.
--
-- Stamping is the expensive part: on Linux CI it was 148 s, charged to whichever
-- case asked for the binary first (#383). The runner stamps it before any case
-- starts (the `prerequisites` in tests/groups.lua) and names it in `variable`.
-- Run without that runner, `path` stamps it itself. Either way a binary is only
-- reused while it is newer than its sources, so a run after
-- `nupp build --target dist` costs nothing at all.

local M = {}

M.TARGET = "dist"
M.PRODUCED = "build/dist/nupp"

--- Where the runner leaves the path of the binary it stamped for this run.
M.variable = "NUPP_TEST_STAMPED_BINARY"

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- The shell command that stamps the binary from ROOT, or keeps the one already
--- there, and prints its absolute path last.
---
--- Reuse is only sound while the artifact still answers for the tree under test.
--- One older than its sources answers for a tree nobody has any more, and the
--- difference it reports then reads as a defect in whatever change is being
--- tested rather than as the stale file it is. A `find` that cannot answer is
--- treated as stale, since stamping again costs a minute and believing this one
--- costs a debugging session.
function M.command(root)
    local produced = quote(M.PRODUCED)
    return table.concat({
        "cd " .. quote(root),
        "if [ ! -f " .. produced .. " ] || ! newer=$(find src nupp.lua -newer " .. produced .. " -print)"
            .. " || [ -n \"$newer\" ]; then ./bin/nupp build --target " .. M.TARGET .. " || exit 1; fi",
        "[ -f " .. produced .. " ] || { echo 'the build produced no " .. M.PRODUCED .. "'; exit 1; }",
        "printf '%s/%s\\n' \"$(pwd -W 2>/dev/null || pwd)\" " .. produced,
    }, " && ")
end

local cached, problem

--- The binary's path, or nil and why there is none.
function M.path(root)
    if cached or problem then
        return cached, problem
    end
    local prepared = os.getenv(M.variable)
    local file = prepared and prepared ~= "" and io.open(prepared, "rb")
    if file then
        file:close()
        cached = prepared
        return cached
    end
    local pipe = assert(io.popen(M.command(root) .. " 2>&1; printf '\n__status__:%s' $?"))
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__status__:(%d+)%s*$"))
    output = output:gsub("\n__status__:%d+%s*$", "")
    if status ~= 0 then
        problem = ("`nupp build --target %s` did not produce a binary:\n%s"):format(M.TARGET, output:sub(-800))
        return nil, problem
    end
    cached = assert(output:match("([^\r\n]+)%s*$"), "the stamp named no binary")

    return cached
end

return M
