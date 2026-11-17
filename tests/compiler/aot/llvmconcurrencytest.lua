-- The code generator from several Lua states of one process at once.
--
-- lld keeps its context in process globals, so two links in one process must
-- not overlap; each worker lane is a Lua state of its own whose module state
-- the others never see, so only a lock the whole process shares can keep them
-- apart. The one-process test runner reaches this whenever two suites build
-- native code side by side (#357).

local codegen = require("nupp.compiler.aot.llvm.codegen")

local M = {}

local KERNEL = [[
define void @scale(ptr %p, i64 %n) {
entry:
  ret void
}
]]

-- Enough links queued across the pool's lanes that several are always running
-- at once.
local LINKS = 64

local function scratch(suffix)
    return require("nupp.compiler.process").tmpname() .. suffix
end

-- On a Windows host an ELF link leaves the process unable to exit through its
-- static destructors, so there the lanes link through lld-link alone.
local function elfObject()
    if package.config:sub(1, 1) == "\\" then
        return nil
    end
    local compiled = assert(codegen.compile(KERNEL, "scale", {triple = "x86_64-unknown-linux-gnu"}))
    local path = scratch(".o")
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
    local scope = require("nupp.workers").__scope()
    local outputs = {}
    local ok, problem = pcall(function()
        local tasks = {}
        for index = 1, LINKS do
            local output = scratch(".a")
            outputs[#outputs + 1] = output
            if object ~= nil and index % 2 == 0 then
                tasks[index] = scope:spawn(codegen.link, {"ld.lld", "-shared", object, "-o", output})
            else
                local names = {{"GetCurrentProcess"}, {"TerminateProcess"}}
                tasks[index] = scope:spawn(codegen.importLibrary, "kernel32.dll", output, names)
            end
        end
        for index, task in ipairs(tasks) do
            local first, second = task:await()
            if object ~= nil and index % 2 == 0 then
                assert(first ~= nil, ("link %d: %s"):format(index, tostring(second)))
            else
                assert(first == nil, ("import library %d: %s"):format(index, tostring(first)))
            end
        end
    end)
    pcall(scope.close, scope)
    for _, output in ipairs(outputs) do
        os.remove(output)
    end
    if object ~= nil then
        os.remove(object)
    end
    assert(ok, problem)
end

return M
