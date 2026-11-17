-- The result of a build the runner prepares for a suite (the `prerequisites`
-- in tests/groups.lua), however it was prepared.
--
-- A build the runner made before any case started is named in the helper's
-- `variable`. One it started in the background is named in `pending`: a path
-- the build writes its output to, with a `.status` file beside it once it has
-- finished, so a case that gets there first waits for it rather than building it
-- a second time. Run without the runner, the case runs the helper's command.

local M = {}

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()

    return text
end

--- What the background build left at RESULT, waiting for it to finish.
local function awaited(result)
    while true do
        local status = readFile(result .. ".status")
        if status then
            return tonumber(status), readFile(result .. ".out") or ""
        end
        os.execute("sleep 1")
    end
end

--- The status and output of HELPER's build from ROOT, with the path it printed
--- last as a third value when it succeeded. Prepared up front, the status is 0,
--- the output is empty and the path is the one the runner exported.
function M.result(helper, root)
    local prepared = os.getenv(helper.variable)
    if prepared and prepared ~= "" then
        return 0, "", prepared
    end
    local status, output
    local pending = helper.pending and os.getenv(helper.pending)
    if pending and pending ~= "" then
        status, output = awaited(pending)
    else
        local pipe = assert(io.popen(helper.command(root) .. " 2>&1; printf '\n__status__:%s' $?"))
        output = pipe:read("*a")
        pipe:close()
        status = tonumber(output:match("__status__:(%d+)%s*$"))
        output = output:gsub("\n__status__:%d+%s*$", "")
    end
    if status ~= 0 then
        return status or -1, output
    end

    return 0, output, output:match("([^\r\n]+)%s*$")
end

return M
