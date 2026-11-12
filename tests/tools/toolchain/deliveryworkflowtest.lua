-- The delivery workflows and the toolchain driver's boundaries: what CI runs,
-- what a release publishes, and what the driver refuses. Nothing here builds a
-- native artifact; the driver runs against fake compilers.

local HERE = require("helpers.paths").absoluteTests
local ROOT = HERE .. "/.."
local DRIVER = ROOT .. "/scripts/toolchain"

local M = {}

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read(path)
    local file = assert(io.open(path, "rb"), path .. " is missing")
    local text = file:read("*a")
    file:close()
    return text
end

local function countOccurrences(text, needle)
    local count = 0
    local cursor = 1
    while true do
        local found = text:find(needle, cursor, true)
        if not found then
            return count
        end
        count = count + 1
        cursor = found + #needle
    end
end

local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

local function temporary()
    local path = os.tmpname()
    os.remove(path)
    assert(os.execute("mkdir -p " .. quote(path)) == 0)
    return path
end

local function run(environment, arguments)
    local prefix = {}
    for name, value in pairs(environment) do
        if name == "PATH" then
            prefix[#prefix + 1] = name .. '="' .. value .. '"'
        else
            prefix[#prefix + 1] = name .. "=" .. quote(value)
        end
    end
    table.sort(prefix)
    local command = (
        "env %s %s %s 2>&1; echo \"__exit__:$?\""
    ):format(table.concat(prefix, " "), quote(DRIVER), arguments)
    local pipe = assert(io.popen(command))
    local output = pipe:read("*a")
    pipe:close()
    local status = tonumber(output:match("__exit__:(%d+)%s*$"))

    return status, (output:gsub("__exit__:%d+%s*$", ""))
end

local function executable(directory, name, source)
    local path = directory .. "/" .. name
    write(path, source)
    assert(os.execute("chmod +x " .. quote(path)) == 0)
    return path
end

local function fakeCompiler(directory, name, version)
    return executable(
        directory,
        name or "fake-cc",
        ("#!/bin/sh\nprintf '%%s\\n' %s\n"):format(quote(version or "fake-cc-1"))
    )
end

-- The GPU provider is Nupp over wgpu-native, which no host links, so a host
-- that asks for it is asking for something that does not exist.
function M.gpuIsNotAHostFeature()
    local directory = temporary()
    local env = {NUPP_TOOLCHAIN_DIR = directory .. "/toolchain", NUPP_CC = fakeCompiler(directory), PATH = "$PATH"}
    for _, name in ipairs({"native-gpu", "gpu"}) do
        local status, output = run(env, "host " .. name)
        assert(status ~= 0, output)
        assert(output:find("unknown host feature " .. name, 1, true), output)
    end
end

function M.gpuConformanceIsValidPosixShell()
    for _, name in ipairs({"test-gpu-conformance.sh", "test-gpu-conformance-windows.sh"}) do
        local script = ROOT .. "/.github/scripts/" .. name
        assert(os.execute("sh -n " .. quote(script)) == 0, name .. " is not valid POSIX shell")
    end
    local workflow = read(ROOT .. "/.github/workflows/compiler.yml")
    local linux = read(ROOT .. "/.github/scripts/test-gpu-conformance.sh")
    local windows = read(ROOT .. "/.github/scripts/test-gpu-conformance-windows.sh")
    local gemm = read(ROOT .. "/bench/wgpu-spike/gemm-api.lua")
    local typedGemm = read(ROOT .. "/bench/wgpu-spike/typed/gemm.nupp")
    assert(workflow:find("GPU conformance / Windows DX12", 1, true), "the compiler matrix has no Windows GPU gate")
    assert(windows:find("WGPU_BACKEND=dx12", 1, true), "Windows GPU conformance does not force DX12")
    assert(windows:find('cygpath -m "$root"', 1, true), "Windows GPU conformance passes POSIX paths to LuaJIT")
    assert(windows:find("$lua_root/build/?.lua", 1, true), "Windows GPU conformance omits compiled Nupp modules")
    assert(linux:find("$root/build/?.lua", 1, true), "Linux GPU conformance omits compiled Nupp modules")
    assert(windows:find("NUPP_REQUIRE_GPU=1", 1, true), "Windows GPU conformance allows adapter absence")
    assert(
        windows:find("export NUPP_TEST_BASH NUPP_TEST_SH", 1, true)
            and windows:find('cygpath -w "$bash_path"', 1, true),
        "Windows GPU conformance leaves tests/run without Git Bash"
    )
    assert(windows:find("gemm-api.lua", 1, true), "Windows GPU conformance does not cross the public Nupp API")
    assert(typedGemm:find('os.monotonic', 1, true), "GPU conformance omits its packaged clock dependency")
    assert(gemm:find("generated.now()", 1, true), "GPU conformance does not use its packaged benchmark clock")
    for name, script in pairs({linux = linux, windows = windows}) do
        assert(script:find('"$root/bin/nupp" test gpudevicetest', 1, true), name .. " does not cross wgpu-native")
        assert(script:find("counted-wgsl.lua", 1, true), name .. " does not execute the emitted WGSL")
        assert(script:find("NUPP_WGPU_LIBRARY", 1, true), name .. " leaves LuaJIT without wgpu-native")
        assert(
            not script:find("cargo test", 1, true) and not script:find("cargo\" test", 1, true),
            name .. " still tests a Rust GPU crate"
        )
    end
end

-- Measurements live in their own workflow. A benchmark harness that does not
-- compile is still a bug, and this is where it is caught; what it must not do
-- is decide the result of an unrelated change, which is why these read
-- `measurements.yml` rather than the gate.
function M.gpuConformanceStaysInTheMergeGate()
    -- No provider is built with or without the GPU any more, so there is
    -- nothing to measure; the conformance gate stays where merging depends on it.
    local workflow = read(ROOT .. "/.github/workflows/measurements.yml")
    assert(not workflow:find("gpu-provider", 1, true), "measurements still build a GPU provider")
    local gate = read(ROOT .. "/.github/workflows/compiler.yml")
    assert(gate:find(".github/scripts/test-gpu-conformance.sh", 1, true), "Vulkan conformance left the merge gate")
    assert(
        gate:find(".github/scripts/test-gpu-conformance-windows.sh", 1, true),
        "DX12 conformance left the merge gate"
    )
end

function M.nativeRuntimeMeasurementsArePortableAndNonThresholded()
    local workflow = read(ROOT .. "/.github/workflows/measurements.yml")
    local measure = read(ROOT .. "/.github/scripts/measure-native-runtime.sh")
    local benchmark = read(ROOT .. "/bench/native-runtime/src/main.nupp")
    local peer = read(ROOT .. "/bench/native-runtime/server.mjs")
    local peerDriver = read(ROOT .. "/bench/native-runtime/peer.sh")
    local resources = read(ROOT .. "/bench/native-runtime/resource.sh")
    local windowsResources = read(ROOT .. "/bench/native-runtime/resource-windows.ps1")

    assert(os.execute("sh -n " .. quote(ROOT .. "/.github/scripts/measure-native-runtime.sh")) == 0)
    assert(os.execute("sh -n " .. quote(ROOT .. "/bench/native-runtime/resource.sh")) == 0)
    assert(os.execute("sh -n " .. quote(ROOT .. "/bench/native-runtime/run.sh")) == 0)
    assert(os.execute("sh -n " .. quote(ROOT .. "/bench/native-runtime/peer.sh")) == 0)
    assert(workflow:find("Native runtime / ${{ matrix.name }}", 1, true))
    assert(workflow:find("native-runtime-${{ matrix.artifact }}-${{ github.sha }}", 1, true))
    assert(
        not read(ROOT .. "/.github/workflows/compiler.yml"):find("measure-native-runtime.sh", 1, true),
        "a measurement fixture can fail the merge gate again"
    )
    assert(measure:find("./bin/nupp build", 1, true), "clean measurement runners do not stage root modules")
    assert(measure:find("bench/native-runtime/run.sh", 1, true))
    assert(measure:find("bench/native-runtime/resource.sh", 1, true))
    -- Net and HTTP are Nupp since #142, ask the provider for nothing since #195,
    -- and URI handling is Nupp since #200, so the benchmark stages no provider
    -- and the measured build is the provider's minimal one, `base`, the only
    -- feature the provider has.
    local features = measure:match("\nfeatures=([%w,%-]+)\n")
    assert(features == "base", "the measured provider build changed its features: " .. tostring(features))
    assert(not measure:find("benchmark_provider", 1, true), "the benchmark stages no provider to measure")
    assert(measure:find('benchmark.exe', 1, true), "Windows benchmark size does not resolve the executable suffix")
    assert(measure:find("observations, not", 1, true), "hosted-runner timings are not identified as observations")
    assert(peer:find("READY ${httpPort} ${tcpPort}", 1, true), "the peer does not publish one coherent ready event")
    assert(not peer:find("process.argv", 1, true), "Node readiness still crosses the Git Bash path boundary")
    assert(peerDriver:find("kill -0", 1, true), "peer readiness does not track the exact child process")
    assert(peerDriver:find("exited with status", 1, true), "peer startup loses the child exit status")
    assert(peerDriver:find("sleep 1", 1, true), "peer readiness relies on nonportable fractional sleeps")
    assert(peerDriver:find("server.log", 1, true), "peer startup failures lose their diagnostics")
    assert(not peerDriver:find("sleep 0.", 1, true), "peer readiness retains fractional Git Bash sleeps")
    assert(resources:find('Windows:*|*:MINGW*|*:MSYS*|*:CYGWIN*', 1, true), "Windows runner detection is incomplete")
    assert(
        resources:find('./bin/nupp build --target compiler --progress=never', 1, true),
        "the direct resource entry point does not stage compiler-owned runtimes"
    )
    assert(not resources:find("ps -W", 1, true), "the sampler still infers a native PID from MSYS process state")
    assert(resources:find("resource-windows.ps1", 1, true), "Windows does not dispatch to its native sampler")
    assert(resources:find('cygpath -w "$benchmark"', 1, true), "the Windows sampler does not receive a native path")
    assert(windowsResources:find("Start-Process @parameters", 1, true), "PowerShell does not own the benchmark child")
    assert(
        windowsResources:find("RedirectStandardOutput = $Output", 1, true)
        and windowsResources:find("RedirectStandardError = $ErrorOutput", 1, true),
        "the Windows benchmark output is not retained for readiness and diagnostics"
    )
    assert(windowsResources:find("$Process.WorkingSet64", 1, true), "Windows RSS is not sampled")
    assert(
        windowsResources:find("$stdout = [string](Read-ChildText -Path $Output)", 1, true),
        "empty Windows child output collapses to null before diagnostics"
    )
    assert(
        windowsResources:find("$processHandle = $process.Handle", 1, true),
        "Windows does not retain its exact child process handle while the benchmark is live"
    )
    assert(
        windowsResources:find("WaitForSingleObject(process, Infinite)", 1, true),
        "Windows does not wait on the retained native process handle"
    )
    assert(
        windowsResources:find("GetExitCodeProcess(process, out exitCode)", 1, true),
        "Windows does not read status from the retained native process handle"
    )
    assert(
        windowsResources:find("WaitForExitCode($processHandle)", 1, true),
        "Windows accepts an empty PowerShell Process.ExitCode as success"
    )
    assert(
        windowsResources:find("$reportedPid -ne [long]$Process.Id", 1, true),
        "the benchmark PID is not checked against the retained Windows process"
    )
    assert(not windowsResources:find("Get-Process", 1, true), "the Windows sampler still rediscovers its child by PID")
    assert(
        windowsResources:find("finally", 1, true)
        and windowsResources:find("Stop-Benchmark -Process $process", 1, true)
        and windowsResources:find("$Process.Kill()", 1, true)
        and windowsResources:find("$Process.WaitForExit()", 1, true),
        "the Windows benchmark child is not cleaned up on failure"
    )
    assert(windowsResources:find("$sampleCount -eq 0", 1, true), "a Windows load run can succeed without an RSS sample")
    assert(windowsResources:find('"load peak_rss_kib=$peak"', 1, true), "the Windows load result format drifted")
    assert(windowsResources:find('"$Mode second=$second rss_kib=$rss"', 1, true), "the Windows probe format drifted")
    assert(
        benchmark:find("unsigned long __stdcall GetCurrentProcessId(void);", 1, true),
        "the Windows benchmark does not declare the Win32 PID API"
    )
    assert(benchmark:find('ffi.load("kernel32")', 1, true), "the Windows benchmark does not load the PID API")
    assert(not benchmark:find("ffi.C._getpid", 1, true), "the Windows benchmark still reads an MSYS C-runtime PID")
    assert(benchmark:find("int getpid(void);", 1, true), "the Unix benchmark does not read its native PID")
    assert(benchmark:find("NUPP_BENCH_PID %d", 1, true), "the benchmark does not report a machine-readable PID")
    assert(resources:find("benchmark_pid()", 1, true), "the resource harness does not require the PID report")
    assert(resources:find('native_pid=$(benchmark_pid "$output" "$BENCH_PID"', 1, true))
    assert(countOccurrences(resources, 'rss=$(rss_kib "$native_pid")') == 2, "Unix load and probes do not sample RSS")
    assert(not resources:find('rss=$(rss_kib "$BENCH_PID")', 1, true), "the shell lifecycle PID is still sampled")
    assert(resources:find('while kill -0 "$BENCH_PID" 2>/dev/null; do', 1, true))
    assert(resources:find('elif kill -0 "$BENCH_PID" 2>/dev/null; then', 1, true))
    assert(
        not resources:find("native_process_running", 1, true),
        "the Win32 RSS identity is still used as the Git Bash lifecycle identity"
    )
    assert(
        resources:find("invalid RSS sample", 1, true),
        "missing or non-numeric RSS samples do not fail the measurement"
    )
    assert(
        not resources:find('rss_kib "$BENCH_PID" 2>/dev/null || true', 1, true),
        "load measurement still hides RSS sampler failures"
    )
    assert(resources:find('if [ "$samples" -eq 0 ]', 1, true), "a load run can succeed without an RSS sample")
    assert(resources:find("measure net-slow-reader", 1, true), "the raw network slow-reader resource probe is absent")
    assert(resources:find("measure net-slow-writer", 1, true), "the raw network slow-writer resource probe is absent")
    assert(resources:find("measure http-slow-writer", 1, true), "the HTTP slow-writer resource probe is absent")
    assert(benchmark:find("NUPP_BENCH_NET_PORT", 1, true), "the raw slow writer has no external peer")
    assert(peer:find("createTcpServer", 1, true), "the raw slow-writer peer is absent")
end

function M.legacyProviderUpgradeBridgeIsGone()
    local driver = read(DRIVER)
    assert(not driver:find("provider_sources", 1, true), "the ABI-v1 feature selector remains in the toolchain")
    assert(not driver:match("\n    native%)"), "the ABI-v1 provider command remains in the toolchain")
end

-- The product builds without Rust (#1, #8), so CI provisions none: no workflow,
-- action or CI script installs a Rust toolchain, runs Cargo, or restores a Rust
-- cache, and the jobs #139 turned off for building Rust run again. The
-- sanitizer workflow and the Rust-native gate over the deleted crates stay gone.
function M.ciProvisionsNoRust()
    local compiler = read(ROOT .. "/.github/workflows/compiler.yml")
    local release = read(ROOT .. "/.github/workflows/release.yml")
    local groups = read(ROOT .. "/tests/groups.lua")

    for _, path in ipairs({
        "/.github/scripts/test-rust-native-platform.sh",
        "/.github/scripts/sanitize-native.sh",
        "/.github/workflows/sanitizers.yml",
    }) do
        assert(not io.open(ROOT .. path, "rb"), path .. " still exists")
    end
    local listing = assert(io.popen("git -C " .. quote(ROOT) .. " ls-files .github"))
    for path in listing:lines() do
        if path ~= ".github/scripts/check-no-rust-or-cpp.sh" then
            local text = read(ROOT .. "/" .. path)
            for _, needle in ipairs({
                "rustup toolchain",
                "rustup target",
                "rustup which",
                "cargo build",
                "cargo test",
                "cargo vendor",
                "rust-toolchain",
                "build/rust",
                "native-rust",
            }) do
                assert(not text:find(needle, 1, true), path .. " still names " .. needle)
            end
            assert(not text:find("Turned off: builds Rust", 1, true), path .. " still turns a job off for building Rust")
        end
    end
    listing:close()
    assert(not groups:find("rust-native-gate", 1, true), "tests/groups.lua still defines the Rust-native gate")
    assert(compiler:find("./bin/nupp fixpoint", 1, true), "the retained compiler matrix has no fixpoint gate")
    assert(
        countOccurrences(release, "./bin/nupp fixpoint --binary") == 2,
        "the retained release matrix does not verify binary packaging fixpoints"
    )
    assert(
        countOccurrences(release, 'NUPP_LUAROCKS=$(cat "$luarocks_dir/.executable")') == 3,
        "release jobs do not use the platform-specific pinned LuaRocks executable"
    )
    assert(
        not release:find("scripts/toolchain luarocks)/bin/luarocks", 1, true),
        "release jobs assume the Unix LuaRocks installation layout"
    )
    assert(release:find("shasum -a 256 -c SHA256SUMS", 1, true), "Unix packaging has no archive fixpoint")
    assert(release:find("release archive checksum mismatch", 1, true), "Windows packaging has no archive fixpoint")
end

-- What `check-no-rust-or-cpp.sh` answers for a list of paths, or for the files
-- git tracks when there is no list.
local function gate(paths)
    local input = paths and os.tmpname()
    local redirect = ""
    if input then
        write(input, table.concat(paths, "\n") .. "\n")
        redirect = " --stdin < " .. quote(input)
    end
    local pipe = assert(io.popen(
        ("sh %s%s 2>&1; echo \"__exit__:$?\""):format(quote(ROOT .. "/.github/scripts/check-no-rust-or-cpp.sh"), redirect)
    ))
    local output = pipe:read("*a")
    pipe:close()
    if input then
        os.remove(input)
    end
    return tonumber(output:match("__exit__:(%d+)%s*$")), output
end

-- The tree holds no Rust and no C++ of its own, and CI keeps it that way.
function M.theTreeHasNoRustOrCxx()
    local status, output = gate()
    assert(status == 0, output)
    local compiler = read(ROOT .. "/.github/workflows/compiler.yml")
    assert(
        compiler:find(".github/scripts/check-no-rust-or-cpp.sh", 1, true),
        "the compiler workflow does not run the Rust and C++ gate"
    )
end

-- Every way Rust or C++ comes back is refused, wherever in the tree it lands,
-- and the C fixtures and benchmark controls #1 keeps are not.
function M.theRustAndCxxGateRefusesWhatItShould()
    for _, path in ipairs({
        "src/nupp/lib.rs",
        "native/provider/build.rs",
        "Cargo.toml",
        "Cargo.lock",
        "native/provider/Cargo.toml",
        "rust-toolchain.toml",
        "rust-toolchain",
        ".cargo/config.toml",
        "native/codegen/glue.cpp",
        "host/stub.cxx",
        "runtime/shim.cc",
        "bench/other/control.cpp",
        "tests/integration/simd/wasmtime-host/src/lib.rs",
    }) do
        local status, output = gate({"README.md", path})
        assert(status == 1, path .. " passed the gate:\n" .. output)
        assert(output:find(path, 1, true), "the gate did not name " .. path .. ":\n" .. output)
    end
    local status, output = gate({
        "tests/fixtures/point.h",
        "tests/fixtures/point.c",
        "bench/simd11/handwritten/base64.c",
        "bench/strings/scan_control.c",
        "bench/serde-spike/serde_spike.cpp",
        "bench/simd-json/native/simdjson_control.cpp",
        "bench/simd-json/native/simdjson_control.h",
        "src/nupp/tools/build/cargo.nupp",
    })
    assert(status == 0, "the gate refused an exempt path:\n" .. output)
end

-- A C++ compiler builds nothing of Nupp's own, so which one a machine has, or
-- whether it has one at all, never moves where the native artifacts live.
function M.thePrefixIgnoresTheCxxCompiler()
    local directory = temporary()
    local compiler = fakeCompiler(directory, "fake-cc", "fake")
    local first = fakeCompiler(directory, "first-cxx", "one")
    local second = fakeCompiler(directory, "second-cxx", "two")
    local env = {NUPP_TOOLCHAIN_DIR = directory .. "/cache", NUPP_CC = compiler, PATH = "$PATH"}
    env.NUPP_CXX = first
    local status, one = run(env, "--prefix")
    assert(status == 0, one)
    env.NUPP_CXX = second
    local againStatus, two = run(env, "--prefix")
    assert(againStatus == 0, two)
    assert(one == two, "two C++ compilers answered two prefixes: " .. one .. " and " .. two)
    local driver = read(DRIVER)
    assert(driver:find('require_cxx "building LLVM"', 1, true), "building LLVM does not ask for a C++ compiler")
    assert(
        driver:find('require_cxx "linking the code generator library"', 1, true),
        "linking the code generator library does not ask for a C++ compiler"
    )
end

function M.macosReleaseSigningIsOptionalButAtomic()
    local selector = ROOT .. "/.github/scripts/select-macos-release-signing.sh"
    local workflow = read(ROOT .. "/.github/workflows/release.yml")
    local directory = temporary()
    local output = directory .. "/output"
    local names = {
        "APPLE_CERTIFICATE",
        "APPLE_CERTIFICATE_PASSWORD",
        "APPLE_SIGNING_IDENTITY",
        "APPLE_ID",
        "APPLE_APP_PASSWORD",
        "APPLE_TEAM_ID",
    }

    local function select(values)
        local environment = {"GITHUB_OUTPUT=" .. quote(output)}
        for _, name in ipairs(names) do
            environment[#environment + 1] = name .. "=" .. quote(values[name] or "")
        end
        os.remove(output)

        return os.execute(table.concat(environment, " ") .. " bash " .. quote(selector) .. " >/dev/null 2>&1")
    end

    assert(os.execute("bash -n " .. quote(selector)) == 0, "the macOS signing selector is not valid Bash")
    assert(select({}) == 0, "a release without Apple credentials did not select unsigned packaging")
    assert(read(output) == "enabled=false\n", "an uncredentialed release enabled signing")
    assert(select({APPLE_ID = "configured"}) ~= 0, "partial Apple credentials did not stop the release")
    assert(not io.open(output, "rb"), "partial Apple credentials selected a signing mode")

    local complete = {}
    for _, name in ipairs(names) do
        complete[name] = "configured"
    end
    assert(select(complete) == 0, "complete Apple credentials did not enable signing")
    assert(read(output) == "enabled=true\n", "complete Apple credentials selected unsigned packaging")

    assert(
        workflow:find("if: steps.macos-signing.outputs.enabled == 'true'", 1, true),
        "Developer ID work is not gated by the selected signing mode"
    )
    assert(
        workflow:find("This archive is not Developer ID signed or notarized.", 1, true),
        "the unsigned archive does not disclose its signing state"
    )
end

function M.taggedReleaseChecksOutBeforePublishing()
    local workflow = read(ROOT .. "/.github/workflows/release.yml")
    local releaseJob = assert(workflow:match("\n  release:(.*)$"), "the release workflow has no publishing job")
    local checkout = assert(
        releaseJob:find("uses: actions/checkout@v4", 1, true),
        "the publishing job does not check out the tagged repository"
    )
    local publish = assert(
        releaseJob:find('gh release create "$GITHUB_REF_NAME"', 1, true),
        "the publishing job does not create the tagged release"
    )
    assert(checkout < publish, "the publishing job verifies the tag before checking it out")
end

-- wgpu-native's prebuilt library statically carries wgpu's own Cargo graph to
-- every GPU program it is staged beside. Its lock file is only in the source
-- archive of the pinned tag, so the committed notice names that tag, and a
-- WGPU_VERSION bump fails here until the notice is regenerated from it.
function M.wgpuNativeRustDependenciesHaveANoticeForThePinnedTag()
    local pinned = assert(read(ROOT .. "/scripts/toolchain.pins"):match("\nWGPU_VERSION=([^\r\n]+)"))
    local notice = read(ROOT .. "/host/notices/wgpu-native-Rust-dependencies.html")
    local generated = assert(
        notice:match('<meta name="wgpu%-native%-version" content="([^"]+)">'),
        "the wgpu-native Rust notice does not name the release it was generated from"
    )
    assert(
        generated == pinned,
        (
            "the wgpu-native Rust notice covers %s but WGPU_VERSION is %s; run "
            .. "scripts/rust-dependency-notices --write wgpu-native"
        ):format(generated, pinned)
    )

    local seen = {}
    local seenCount = 0
    for marker in notice:gmatch('data%-crate="([^"]+)"') do
        assert(marker:match("^[%w_%-]+@[%w%.%+%-]+$"), "malformed wgpu-native notice entry " .. marker)
        assert(not seen[marker], "wgpu-native Rust notice repeats package " .. marker)
        seen[marker] = true
        seenCount = seenCount + 1
    end
    assert(seenCount > 0, "the wgpu-native Rust notice lists no packages")
    for _, crate in ipairs({"wgpu-core", "wgpu-hal", "wgpu-types", "naga"}) do
        assert(notice:find('data-crate="' .. crate .. "@", 1, true), "wgpu-native Rust notice omits " .. crate)
    end

    local row = assert(
        read(ROOT .. "/host/NOTICE.md"):match("\n(| %[wgpu%-native%][^\n]*)"),
        "the release notice has no wgpu-native row"
    )
    assert(row:find("`" .. pinned .. "`", 1, true), "the release notice's wgpu-native row does not name " .. pinned)
    assert(
        row:find("notices/wgpu-native-Rust-dependencies.html", 1, true),
        "the release notice's wgpu-native row does not point readers to its Rust notice"
    )
end

return M
