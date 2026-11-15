-- Ordinary-harness support for the compact pure-Wasm conformance packs.
local M = {}
local runner = require("tests.integration.simd.runner")
local hash = require("nupp.compiler.hash")
local root = runner.root()

local function exists(path)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end

    return false
end

local function basename(path)
    return assert(path:gsub("\\", "/"):match("([^/]+)$"), "path has no basename: " .. path)
end

local function firstLine(text)
    return text:match("[^\r\n]+") or ""
end

local function tool(command, arguments, environment)
    local log = os.tmpname()
    local code = os.execute(
        (
            environment or ""
        ) .. runner.quote(command) .. " " .. (arguments or "--version") .. " >" .. runner.quote(log) .. " 2>&1"
    )
    local output = exists(log) and runner.read(log) or ""
    os.remove(log)

    return {
        available = code == 0,
        command = command,
        version = firstLine(output),
        output = code == 0 and nil or output,
    }
end

-- Wasmtime's prebuilt C API, which wasmtime-host.lua drives through LuaJIT's
-- FFI. Each release archive has its own digest, named by the host it serves,
-- and the digest is what a download or a supplied copy is held to. The Windows
-- x86_64 build is the MinGW one, which needs nothing beyond the system DLLs.
local WASMTIME_VERSION = "v48.0.2"
local WASMTIME_URL = "https://github.com/bytecodealliance/wasmtime/releases/download/"
local WASMTIME_ARCHIVES = {
    ["Linux-x64"] = {
        platform = "x86_64-linux",
        suffix = ".tar.xz",
        library = "lib/libwasmtime.so",
        sha256 = "d9a2b5dfaf688035f288a7ae81a4b96c3acdd3e849262c2ab577b61908c3f9f9",
    },
    ["Linux-arm64"] = {
        platform = "aarch64-linux",
        suffix = ".tar.xz",
        library = "lib/libwasmtime.so",
        sha256 = "af6d19b2bf6a3147b7550356f557dc5a5e538a70c099f4c435d12311e20e5c6c",
    },
    ["OSX-x64"] = {
        platform = "x86_64-macos",
        suffix = ".tar.xz",
        library = "lib/libwasmtime.dylib",
        sha256 = "5fbf2c7700063282000dcefe9d0691ac9e27f2f213746acd56f42d1772cebe4a",
    },
    ["OSX-arm64"] = {
        platform = "aarch64-macos",
        suffix = ".tar.xz",
        library = "lib/libwasmtime.dylib",
        sha256 = "c4b95346d92168963607f8ac56ef70298aa83b9d2b23af3e801759df3443ed09",
    },
    ["Windows-x64"] = {
        platform = "x86_64-mingw",
        suffix = ".zip",
        library = "lib/wasmtime.dll",
        sha256 = "597cc4c2fd2dc7e58ac1e217fc9b3a56026831a3ed69e389f381a48846556714",
    },
}

local function offline()
    local value = (os.getenv("NUPP_HOST_OFFLINE") or ""):lower()
    return value == "1" or value == "true" or value == "yes" or value == "on"
end

-- The pinned C API archive for this host, and how it can be had: from
-- NUPP_HOST_SOURCE_DIR, the directory of already-downloaded pinned archives
-- scripts/toolchain also reads, or downloaded unless NUPP_HOST_OFFLINE is set.
local function pinnedHost()
    local host = jit.os .. "-" .. jit.arch
    local pin = WASMTIME_ARCHIVES[host]
    if not pin then
        return {
            available = false,
            source = "pinned",
            version = WASMTIME_VERSION,
            reason = "Wasmtime " .. WASMTIME_VERSION .. " publishes no pinned C API library for " .. host,
        }
    end
    local name = "wasmtime-" .. WASMTIME_VERSION .. "-" .. pin.platform .. "-c-api"
    local sourceDir = os.getenv("NUPP_HOST_SOURCE_DIR")
    local supplied = sourceDir and sourceDir ~= "" and sourceDir .. "/" .. name .. pin.suffix or nil
    if supplied and not exists(supplied) then
        supplied = nil
    end
    local extractor = pin.suffix == ".zip" and tool("unzip", "-v") or tool("tar")
    local downloader = tool("curl")
    local digest = tool("sha256sum")
    if not digest.available then
        digest = tool("shasum")
    end
    local reason
    if not extractor.available then
        reason = "unpacking the Wasmtime C API needs " .. extractor.command
    elseif not digest.available then
        reason = "verifying the Wasmtime C API needs sha256sum or shasum"
    elseif not supplied and offline() then
        reason = "NUPP_HOST_OFFLINE is set and NUPP_HOST_SOURCE_DIR has no " .. name .. pin.suffix
    elseif not supplied and not downloader.available then
        reason = "fetching the Wasmtime C API needs curl"
    end

    return {
        available = reason == nil,
        source = "pinned",
        version = WASMTIME_VERSION,
        archive = name .. pin.suffix,
        library = name .. "/" .. pin.library,
        sha256 = pin.sha256,
        supplied = supplied,
        digest = digest.command,
        reason = reason,
    }
end

function M.capabilities()
    local lua = os.getenv("NUPP_SIMD_LUA") or "luajit"
    local library = os.getenv("NUPP_WASMTIME_LIBRARY")
    local capabilities = {node = tool("node"), lua = tool(lua, "-v"),}
    -- nupp compiles and links the Wasm itself, through its own LLVM.
    local version, problem = runner.codegen()
    capabilities.wasm = {available = version ~= nil, command = "nupp", version = version, output = problem,}
    capabilities.lua.runtime = jit.version
    capabilities.lua.os = jit.os
    capabilities.lua.arch = jit.arch
    if library and library ~= "" then
        local found = exists(library)
        capabilities.host = {
            available = found,
            source = "NUPP_WASMTIME_LIBRARY",
            path = library,
            reason = not found and ("NUPP_WASMTIME_LIBRARY names no file: " .. library) or nil,
        }
    else
        capabilities.host = pinnedHost()
    end

    return capabilities
end

local function digestFiles(prefix, paths, extra)
    local parts = {prefix}
    for _, path in ipairs(paths) do
        parts[#parts + 1] = path:sub(#root + 1)
        parts[#parts + 1] = runner.read(path)
    end
    for _, value in ipairs(extra or {}) do
        parts[#parts + 1] = tostring(value)
    end

    return hash.digest(table.concat(parts, "\0"))
end

-- The Wasmtime C API library and its identity. A pinned archive is fetched or
-- copied, verified and unpacked once, into a fixture keyed by its digest.
function M.host(test, capabilities)
    local host = capabilities.host
    if host.source == "NUPP_WASMTIME_LIBRARY" then
        return host.path, {key = "prebuilt-" .. hash.digest(runner.read(host.path)), source = "prebuilt",}
    end
    local key = "simd-wasmtime-capi-" .. hash.digest(
        table.concat({"simd-wasmtime-capi-v1", host.version, host.archive, host.sha256}, "\0")
    )
    local directory, evidence = test.suite.fixture(key, function(private)
        local archive = private .. "/" .. host.archive
        if host.supplied then
            runner.command("cp " .. runner.quote(host.supplied) .. " " .. runner.quote(archive), private .. "/fetch.log")
        else
            local base = os.getenv("NUPP_HOST_SOURCE_BASE_URL")
            local url = base and base ~= "" and base:gsub("/$", "") .. "/" .. host.archive
                or WASMTIME_URL .. host.version .. "/" .. host.archive
            -- The scheme travels as a flag: the Windows test shell rewrites every
            -- `x:/` in a command as a drive path, `https://` included.
            local scheme, location = url:match("^(%a+)://(.*)$")
            runner.command(
                "curl --fail --location --silent --show-error --proto-default " .. scheme .. " --output " .. runner.quote(
                    archive
                ) .. " " .. runner.quote(location),
                private .. "/fetch.log"
            )
        end
        local flags = host.digest == "shasum" and " -a 256 " or " "
        local found = runner.command(host.digest .. flags .. runner.quote(archive), private .. "/digest.log")
        found = found:match("^(%x+)")
        assert(
            found == host.sha256,
            host.archive .. " has digest " .. tostring(found) .. ", expected " .. host.sha256 .. "; refusing it"
        )
        local unpack = "tar -xJf " .. runner.quote(archive) .. " -C " .. runner.quote(private)
        if host.archive:sub(-4) == ".zip" then
            unpack = "unzip -q -o " .. runner.quote(archive) .. " -d " .. runner.quote(private)
        end
        runner.command(
            unpack .. " " .. runner.quote(host.library) .. " && rm -f " .. runner.quote(archive),
            private .. "/unpack.log"
        )
        assert(exists(private .. "/" .. host.library), host.archive .. " did not contain " .. host.library)

        return {library = host.library, version = host.version, sha256 = host.sha256,}
    end)

    return directory .. "/" .. evidence.library, {
        key = key,
        source = "pinned",
        version = evidence.version,
        library = basename(evidence.library),
    }
end

local function generatedSources(generated)
    local paths = {}
    for path in pairs(generated.files) do
        paths[#paths + 1] = path
    end
    table.sort(paths)
    local parts = {}
    for _, path in ipairs(paths) do
        parts[#parts + 1] = path
        parts[#parts + 1] = generated.files[path]
    end

    return parts
end

function M.fixtureKey(pack, generated, capabilities, host)
    local paths = {
        root .. "/tests/integration/simd/runner.lua",
        root .. "/tests/integration/simd/wasmtime.lua",
        root .. "/tests/integration/simd/run-wasmtime-guest.lua",
        root .. "/tests/integration/simd/wasmtime-host.lua",
        root .. "/tests/integration/simd/prepare-wasm-reference.lua",
        root .. "/tests/integration/simd/native-packs.lua",
    }
    local extra = generatedSources(generated)
    extra[#extra + 1] = pack
    extra[#extra + 1] = capabilities.wasm.version
    extra[#extra + 1] = capabilities.node.version
    extra[#extra + 1] = capabilities.lua.command
    extra[#extra + 1] = capabilities.lua.runtime
    extra[#extra + 1] = capabilities.lua.os
    extra[#extra + 1] = capabilities.lua.arch
    extra[#extra + 1] = host.key
    extra[#extra + 1] = require("nupp.compiler.project.fingerprint").toolFingerprint()

    return "simd-wasmtime-pack-" .. digestFiles("simd-wasmtime-pack-v3", paths, extra)
end

local function sortedKeys(values)
    local keys = {}
    for key in pairs(values or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    return keys
end

local function routeIdentity(simd, scalar, selection)
    local simdKeys = sortedKeys(simd.symbols)
    local scalarKeys = sortedKeys(scalar.symbols)
    assert(table.concat(simdKeys, "\0") == table.concat(scalarKeys, "\0"), "Wasm route probe inventories differ")
    assert(#simdKeys == simd.probes, "Wasm symbol inventory differs from probe count")
    assert(selection.executionPath == "scalar-c", "scalar-C route selection is missing")
    assert(selection.referenceCases == simd.cases, "scalar-C reference case count differs")
    assert(selection.referenceProbes == simd.probes, "scalar-C reference probe count differs")
    assert(selection.referenceCalls == simd.nativeCalls, "scalar-C reference call count differs")
    assert(type(selection.units) == "table" and #selection.units > 0, "scalar-C route selected no Wasm units")
    local original, rewritten, examples = {}, {}, {}
    table.sort(selection.units, function(left, right)
        return left.unit < right.unit
    end)
    for _, unit in ipairs(selection.units) do
        assert(type(unit.originalWasmSha256) == "string" and #unit.originalWasmSha256 == 64, "missing SIMD Wasm digest")
        assert(type(unit.wasmSha256) == "string" and #unit.wasmSha256 == 64, "missing scalar-C Wasm digest")
        assert(unit.originalWasmSha256 ~= unit.wasmSha256, "SIMD and scalar-C Wasm artifacts are identical")
        original[#original + 1] = unit.unit .. "=" .. unit.originalWasmSha256
        rewritten[#rewritten + 1] = unit.unit .. "=" .. unit.wasmSha256
        if #examples < 3 then
            examples[#examples + 1] = {unit = unit.unit, simd = unit.originalWasmSha256, scalarC = unit.wasmSha256,}
        end
    end
    local simdDigest = hash.digest(table.concat(original, "\0"))
    local scalarDigest = hash.digest(table.concat(rewritten, "\0"))
    assert(simdDigest ~= scalarDigest, "SIMD and scalar-C Wasm inventories are identical")

    return {distinct = true, units = #selection.units, simd = simdDigest, scalarC = scalarDigest, examples = examples,}
end

function M.execute(capabilities, hostLibrary, project, route, log)
    assert(route == "simd" or route == "scalar-c", "unknown Wasmtime execution route")
    runner.command(
        "NUPP_SIMD_HOST_MANIFEST= " .. runner.quote(
            capabilities.lua.command
        ) .. " " .. runner.quote(
            root .. "/tests/integration/simd/run-wasmtime-guest.lua"
        ) .. " " .. runner.quote(project) .. " " .. runner.quote(hostLibrary) .. " " .. route,
        log
    )

    return runner.json(project .. "/result.json")
end

function M.produce(pack, generated, capabilities, hostLibrary, directory)
    local simdDirectory = directory .. "/simd"
    runner.wasm(generated, {directory = simdDirectory})
    local simd = M.execute(capabilities, hostLibrary, simdDirectory, "simd", directory .. "/simd-execution.log")
    local scalarDirectory = directory .. "/scalar-c"
    runner.command(
        runner.quote(
            capabilities.lua.command
        ) .. " " .. runner.quote(
            root .. "/tests/integration/simd/prepare-wasm-reference.lua"
        ) .. " " .. runner.quote(simdDirectory) .. " " .. runner.quote(scalarDirectory),
        directory .. "/scalar-build.log"
    )
    local scalar = M.execute(
        capabilities,
        hostLibrary,
        scalarDirectory,
        "scalar-c",
        directory .. "/scalar-execution.log"
    )
    local selection = runner.json(scalarDirectory .. "/scalar-selection.json")
    assert(simd.runtime == "Wasmtime 48 embedded host" and scalar.runtime == simd.runtime, "unpinned Wasm runtime")
    assert(simd.executionPath == "simd" and scalar.executionPath == "scalar-c", "Wasm route identity is missing")
    assert(simd.cases == scalar.cases and simd.probes == scalar.probes, "Wasm routes executed different corpus counts")
    assert(simd.nativeCalls == scalar.nativeCalls and simd.nativeCalls > 0, "Wasm routes executed different calls")
    assert(
        simd.oracleNumericForRuntime == scalar.oracleNumericForRuntime,
        "Wasm routes used different oracle numeric-for runtimes"
    )
    assert(
        simd.oracleNumericForGuardBridges == scalar.oracleNumericForGuardBridges,
        "Wasm routes adapted different numeric-for guard inventories"
    )
    assert(
        type(simd.oracleNumericForGuardBridges) == "number" and simd.oracleNumericForGuardBridges >= 0,
        "Wasm oracle numeric-for adaptation count is missing"
    )
    assert(
        runner.read(simdDirectory .. "/corpus.json") == runner.read(scalarDirectory .. "/corpus.json"),
        "Wasm routes did not execute one authored corpus"
    )
    local identity = routeIdentity(simd, scalar, selection)
    local sourceBytes, sourceFiles = 0, 0
    for _, source in pairs(generated.files) do
        sourceBytes = sourceBytes + #source
        sourceFiles = sourceFiles + 1
    end
    local manifest = runner.json(simdDirectory .. "/dist/aot/units.json")
    local report = {
        pack = pack,
        runtime = simd.runtime,
        tier = simd.tier,
        routes = {"simd", "scalar-c"},
        cases = simd.cases,
        probes = simd.probes,
        simdCalls = simd.nativeCalls,
        scalarCalls = scalar.nativeCalls,
        sameOracle = true,
        oracleNumericForRuntime = simd.oracleNumericForRuntime,
        oracleNumericForGuardBridges = simd.oracleNumericForGuardBridges,
        routeIdentity = identity,
        work = {
            generatedSourceBytes = sourceBytes,
            generatedSourceFiles = sourceFiles,
            generatedUnits = #manifest.units,
            scalarCompiledUnits = #selection.units,
            buildCommands = 2,
        },
    }

    return report
end

return M
