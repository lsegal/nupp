-- The C embedding SDK the host suites link against.
--
-- hostembeddingtest and hostchanneltest share one feature list, so a run builds
-- one SDK for both. Its cold build was charged to whichever case asked first
-- (#371), so the runner prepares it (the `prerequisites` in tests/groups.lua).
-- It used to before any suite started, which on Windows CI was most of the 64 s
-- before the first one did (#399). It now starts in the background when the run
-- begins and its suites are dealt last, so the build overlaps other suites. The
-- toolchain takes only its own cache locks, not the checkout's build lock, so
-- nothing running beside it waits on it. Run without that runner, `path` asks
-- the toolchain itself.

local prerequisite = require("helpers.prerequisite")

local M = {}

M.FEATURES = "lpeg,native-checksum,native-compression,native-files,native-net,native-process,native-time,native-tls,workers"

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\''") .. "'"
end

--- The shell command that builds the SDK, or names the cached one, from ROOT.
function M.command(root)
    return ("cd %s && ./scripts/toolchain host-library %s"):format(quote(root), M.FEATURES)
end

--- Where the runner leaves the path of the SDK it built for this run.
M.variable = "NUPP_TEST_EMBEDDING_SDK"

--- Where the runner leaves the result of the build it started in the background.
M.pending = "NUPP_TEST_EMBEDDING_SDK_PENDING"

local cached, problem

--- The SDK's directory, or nil and the toolchain's output when it cannot be built.
function M.path(root)
    if not cached and not problem then
        local status, output, path = prerequisite.result(M, root)
        if status ~= 0 or not path then
            problem = output ~= "" and output or "toolchain named no SDK"
        else
            cached = path
        end
    end

    return cached, problem
end

return M
