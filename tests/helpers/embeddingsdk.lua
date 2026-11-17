-- The C embedding SDK the host suites link against.
--
-- hostembeddingtest and hostchanneltest share one feature list, so a run builds
-- one SDK for both. The runner builds it before any case starts (the
-- `prerequisites` in tests/groups.lua), and `path` then finds it in the
-- toolchain's cache, so its cold build is never charged to whichever case asked
-- first (#371).

local M = {}

M.FEATURES = "lpeg,native-checksum,native-compression,native-files,native-net,native-process,native-time,native-tls,workers"

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- The shell command that builds the SDK, or names the cached one, from ROOT.
function M.command(root)
    return ("cd %s && ./scripts/toolchain host-library %s"):format(quote(root), M.FEATURES)
end

local cached

--- The SDK's directory, or nil and the toolchain's output when it cannot be built.
function M.path(root)
    if cached then
        return cached
    end
    local pipe = assert(io.popen(M.command(root) .. " 2>&1; printf '\n__status__:%s' $?"))
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__status__:(%d+)%s*$"))
    output = output:gsub("\n__status__:%d+%s*$", "")
    if status ~= 0 then
        return nil, output
    end
    cached = assert(output:match("([^\r\n]+)%s*$"), "toolchain named no SDK")

    return cached
end

return M
