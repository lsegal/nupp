local testAssert = require("assert")
local T = require("nupp.compiler.types")
local bundled = require("nupp.compiler.bundled")
local envMod = require("nupp.compiler.project.env")
local stdlibimage = require("nupp.compiler.project.stdlibimage")

local M = {}

-- A stand-in for an environment built from the prelude image: an arena of the
-- prelude's tables and one checked module whose interface names one of them.
local function fakeEnv(layoutTarget)
    local shared = T.nominal("Shared", "record", "nupp:prelude.d.nupp\0Shared")
    local make = T.func({T.number}, {shared})
    local moduleType = T.shape({
        {name = "make", read = make}
    })
    local env = {
        layoutTarget = layoutTarget or "i686-unknown-linux-gnu",
        preludeArena = {{}, shared},
        annotations = {
            definedBy = function()
                return {}
            end,
        },
        bundled = {
            ["sample.module"] = {
                path = "sample.module",
                type = moduleType,
                exports = {
                    types = {Shared = shared},
                    typeDefs = {},
                    values = {make = make},
                    valueDefs = {},
                    comptimeFunctions = {},
                    callGuarantees = {},
                    nominalEffectFingerprint = "fingerprint",
                },
                compatDiagnostics = {},
                declarationOnly = false,
                declared = true,
            },
            ["failed.module"] = false,
        },
    }

    return env, shared, make, moduleType
end

local function carrying(data, operation)
    local original = bundled.source
    bundled.source = function(path)
        if path == "/stdlibimage.bin" then
            return data
        end
        return original(path)
    end
    local ok, first, second = pcall(operation)
    bundled.source = original
    if not ok then
        error(first, 0)
    end

    return first, second
end

function M.anImagedModuleNamesThePreludesOwnTypes()
    local env, shared, make, moduleType = fakeEnv()
    local data = assert(stdlibimage.encode(env, {"failed.module", "missing.module", "sample.module"}))
    local hydrated, problem = carrying(data, function()
        return stdlibimage.hydrate(env)
    end)
    assert(hydrated, problem)
    testAssert.eq(hydrated.semantics["failed.module"], nil, "a module that did not check is left out")
    testAssert.eq(hydrated.semantics["missing.module"], nil, "a module that is not there is left out")
    local semantic = assert(hydrated.semantics["sample.module"])
    testAssert.eq(semantic.exports.types.Shared, shared, "a prelude type comes back as the prelude's own")
    local decoded = semantic.exports.values.make
    testAssert.eq(decoded.tag, make.tag, "a function stays a function")
    testAssert.eq(decoded.params[1], T.number, "a primitive is the checker's own")
    testAssert.eq(decoded.retPack.head[1], shared, "so is a prelude type reached through a structural one")
    testAssert.eq(semantic.interface.type.tag, moduleType.tag, "the module's value type")
    testAssert.eq(semantic.exports.nominalEffectFingerprint, nil, "an image is never rechecked")
    testAssert.eq(hydrated.modules["sample.module"].declared, true, "declared")
    testAssert.eq(hydrated.modules["sample.module"].declarationOnly, false, "declaration only")
end

function M.theImageIsByteReproducible()
    local env = fakeEnv()
    local first = assert(stdlibimage.encode(env, {"sample.module"}))
    local second = assert(stdlibimage.encode(env, {"sample.module"}))
    testAssert.eq(first, second, "the same graph writes the same bytes")
end

function M.anImageForOtherSettingsIsRefused()
    local data = assert(stdlibimage.encode(fakeEnv(), {"sample.module"}))
    local other = fakeEnv("x86_64-unknown-linux-gnu")
    local hydrated, problem = carrying(data, function()
        return stdlibimage.hydrate(other)
    end)
    testAssert.eq(hydrated, nil, "another layout target checks from source")
    assert(problem:find("layoutTarget", 1, true), problem)
    local compat = fakeEnv()
    compat.compat = "lua51"
    hydrated = carrying(data, function()
        return stdlibimage.hydrate(compat)
    end)
    testAssert.eq(hydrated, nil, "another compatibility profile checks from source")
    local checked = fakeEnv()
    checked.preludeArena = nil
    hydrated = carrying(data, function()
        return stdlibimage.hydrate(checked)
    end)
    testAssert.eq(hydrated, nil, "a prelude checked from source has no arena to refer into")
end

function M.aDamagedOrAbsentImageIsRefused()
    local env = fakeEnv()
    local data = assert(stdlibimage.encode(env, {"sample.module"}))
    for _, damaged in ipairs({"", data:sub(1, #data - 1), data .. "\0", "NUPP-OTHER\n"}) do
        local hydrated = carrying(damaged, function()
            return stdlibimage.hydrate(env)
        end)
        testAssert.eq(hydrated, nil, "damaged image of " .. #damaged .. " bytes")
    end
end

function M.anEnvironmentTakesImagedModulesInsteadOfCheckingThem()
    local hydrations = 0
    local moduleType = T.shape({
        {name = "imaged", read = T.boolean}
    })
    local env = envMod.new(".", {
        cache = false,
        memoryOnly = true,
        nativeCompilerServices = false,
        typeRoots = {},
        stdlibImage = {
            hydrate = function()
                hydrations = hydrations + 1
                return {
                    semantics = {
                        ["nupp.suspension"] = {
                            interface = {type = moduleType},
                            exports = {types = {}, typeDefs = {}, values = {}, valueDefs = {}, comptimeFunctions = {}},
                            diags = {},
                            annotations = {},
                        },
                    },
                    modules = {["nupp.suspension"] = {declarationOnly = false, declared = true}},
                }
            end,
        },
    })
    testAssert.eq(hydrations, 0, "nothing is decoded until a bundled module is asked for")
    local record = assert(env.bundled["nupp.suspension"])
    testAssert.eq(record.type, moduleType, "the imaged interface stands for the module")
    testAssert.eq(record.declared, true, "declared")
    testAssert.eq(record.inProgress, false, "complete")
    assert(type(record.source) == "string" and #record.source > 0, "the carried source stays readable")
    testAssert.eq(env.loadedPaths["nupp.suspension"], record, "recorded by path")
    testAssert.eq(envMod.resolveModule(env, "nupp.suspension"), moduleType, "resolved through the image")
    testAssert.eq(hydrations, 1, "the image is decoded once")
end

return M
