-- The stamped compiler binary hostbinarytest mistreats.
--
-- Stamping is the expensive part: on Linux CI it was 148 s, charged to whichever
-- case asked for the binary first (#383). The runner stamps it before any case
-- starts (the `prerequisites` in tests/groups.lua) and names it in `variable`.
-- Run without that runner, `path` stamps it itself. Either way a binary is only
-- reused while it is newer than its sources, so a run after
-- `nupp build --target dist` costs nothing at all.

local prerequisite = require("helpers.prerequisite")

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
    local script = [[
cd %s || exit 1
if [ ! -f %s ] || ! newer=$(find src nupp.lua -newer %s -print) || [ -n "$newer" ]; then
    ./bin/nupp build --target %s || exit 1
fi
[ -f %s ] || { echo 'the build produced no %s'; exit 1; }
printf '%%s/%%s\n' "$(pwd -W 2>/dev/null || pwd)" %s]]
    local produced = quote(M.PRODUCED)

    -- A subshell, so `exit` ends the script rather than whatever runs it.
    return "(" .. script:format(quote(root), produced, produced, M.TARGET, produced, M.PRODUCED, produced) .. ")"
end

local cached, problem

--- The binary's path, or nil and why there is none.
function M.path(root)
    if not cached and not problem then
        local status, output, path = prerequisite.result(M, root)
        if status ~= 0 or not path then
            problem = ("`nupp build --target %s` did not produce a binary:\n%s"):format(M.TARGET, output:sub(-800))
        else
            cached = path
        end
    end

    return cached, problem
end

return M
