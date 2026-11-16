-- The code generator from several Lua states of one process at once.
--
-- lld keeps its context in process globals, so two links in one process must
-- not overlap; each worker lane is a Lua state of its own whose module state
-- the others never see, so only a lock the whole process shares can keep them
-- apart. The one-process test runner reaches this whenever two suites build
-- native code side by side (#357).

local codegen = require("nupp.compiler.aot.llvm.codegen")
local links = require("helpers.codegenlinks")

local M = {}

local KERNEL = [[
define void @scale(ptr %p, i64 %n) {
entry:
  ret void
}
]]

local LANES = 4

local ROUNDS = 12

-- On a Windows host an ELF link leaves the process unable to exit through its
-- static destructors, so there the lanes link through lld-link alone.
local function elfObject()
    if package.config:sub(1, 1) == "\\" then
        return ""
    end
    local compiled = assert(codegen.compile(KERNEL, "scale", {triple = "x86_64-unknown-linux-gnu"}))
    local path = require("nupp.compiler.process").tmpname() .. ".o"
    local file = assert(io.open(path, "wb"))
    file:write(compiled.object)
    file:close()

    return path
end

function M.lldLinksFromSeveralStatesAtOnce()
    if not codegen.available() then
        return
    end
    local object = elfObject()
    local workers = require("nupp.workers")
    local scope = workers.__scope()
    local tasks = {}
    local ok, problem = pcall(function()
        for lane = 1, LANES do
            tasks[lane] = scope:worker(links.links, object, ROUNDS)
        end
        for lane, task in ipairs(tasks) do
            local done = task:await()
            local expected = object == "" and ROUNDS or 2 * ROUNDS
            assert(done == expected, ("lane %d: %s"):format(lane, tostring(done)))
        end
    end)
    pcall(scope.close, scope)
    if object ~= "" then
        os.remove(object)
    end
    assert(ok, problem)
end

return M
