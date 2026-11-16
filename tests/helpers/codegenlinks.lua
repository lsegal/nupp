-- What llvmconcurrencytest runs on each worker lane: in-process lld links from
-- a Lua state of the lane's own, beside the other lanes' links.

local codegen = require("nupp.compiler.aot.llvm.codegen")

local M = {}

local function scratch(suffix)
    return require("nupp.compiler.process").tmpname() .. suffix
end

--- Writes `rounds` import libraries through lld-link's librarian mode and, when
--- `object` names an ELF object, links it into a shared object as many times.
--- @return the number of links that succeeded, or the first failure
function M.links(object, rounds)
    local done = 0
    for _ = 1, rounds do
        local path = scratch(".a")
        local err = codegen.importLibrary("kernel32.dll", path, {{"GetCurrentProcess"}, {"TerminateProcess"}})
        os.remove(path)
        if err ~= nil then
            return "import library: " .. tostring(err)
        end
        done = done + 1
        if object ~= "" then
            local output = scratch(".so")
            local _, failure = codegen.link({"ld.lld", "-shared", object, "-o", output})
            os.remove(output)
            if failure ~= nil then
                return "ld.lld: " .. tostring(failure)
            end
            done = done + 1
        end
    end

    return done
end

return M
