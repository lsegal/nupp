-- The C embedding SDK the host suites link against.
--
-- hostembeddingtest and hostchanneltest share one feature list, so a run builds
-- one SDK for both. The runner builds it before any case starts (the
-- `prerequisites` in tests/groups.lua) and names it in `variable`, so its cold
-- build is never charged to whichever case asked first (#371). Run without that
-- runner, `path` asks the toolchain itself.

local M = {}

M.FEATURES = "lpeg,native-checksum,native-compression,native-files,native-net,native-process,native-time,native-tls,workers"

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- The shell command that builds the SDK, or names the cached one, from ROOT.
function M.command(root)
    return ("cd %s && ./scripts/toolchain host-library %s"):format(quote(root), M.FEATURES)
end

--- Where the runner leaves the path of the SDK it built for this run.
M.variable = "NUPP_TEST_EMBEDDING_SDK"

local cached

--- The SDK's directory, or nil and the toolchain's output when it cannot be built.
function M.path(root)
    if cached then
        return cached
    end
    local prepared = os.getenv(M.variable)
    local manifest = prepared and prepared ~= "" and io.open(prepared .. "/link.json", "rb")
    if manifest then
        manifest:close()
        cached = prepared
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
