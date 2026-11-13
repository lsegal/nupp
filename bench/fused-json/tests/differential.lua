-- Run the repository's independent JSON and first-error corpus against the
-- compiled benchmark decoder, including every byte offset across vector tails.
local module = "nupp.codec.json.internal.decoder.fusedbench"
local fused = require(module)
local proveNative = assert(loadfile("../../tests/integration/simd/nativeproof.lua"))()
proveNative(module, function()
    local value, status = fused.decodeEager('["native proof",123]', nil, {}, {})
    assert(status == 0 and value[1] == "native proof" and value[2] == 123, "native proof decode failed")
end)
package.loaded["nupp.codec.json.internal.decoder.fused"] = fused
package.loaded["nupp.codec.json.aot"] = nil
-- The corpus loads the codec over the compiled decoder above. The compiler's
-- build does not carry the codec; the test runner's build does.
if not package.searchpath("nupp.codec.json.aot", package.path) then
    error(
        "the fused JSON differential needs nupp.codec.json.aot, which this"
            .. " LUA_PATH does not reach; build the test runner with"
            .. " `bin/nupp build --target testRunner` and put build/test-runner on"
            .. " LUA_PATH:\n" .. package.path,
        0
    )
end
local suite = dofile("../../tests/stdlib/serde/json/jsonfuseddifferentialtest.lua")
local names = {}
for name in pairs(suite) do
    names[#names + 1] = name
end
table.sort(names)
for _, name in ipairs(names) do
    suite[name]()
    print("passed " .. name)
end
print(("%d compiled decoder differential tests passed"):format(#names))

print("SIMD_CHECKS=" .. #names)
