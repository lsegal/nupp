#!/bin/sh
# Exact wgpu-native dispatch/readback through the retained Windows DX12 backend.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$root"
export WGPU_BACKEND=dx12
export NUPP_REQUIRE_GPU=1
export NUPP_EXPECT_GPU_BACKEND=dx12

# `tests/run` refuses to start on Windows without Git Bash named, the same way
# the Windows matrix job names it. Keep a caller's choice when it made one.
bash_path=$(command -v bash)
sh_path=$(dirname "$bash_path")/sh.exe
test -f "$sh_path"
NUPP_TEST_BASH=${NUPP_TEST_BASH:-$(cygpath -w "$bash_path")}
NUPP_TEST_SH=${NUPP_TEST_SH:-$(cygpath -w "$sh_path")}
export NUPP_TEST_BASH NUPP_TEST_SH

# First cross the wgpu-native boundary with a small WGSL compute kernel.
"$root/bin/nupp" build
"$root/bin/nupp" test gpudevicetest

# Then cross the public Nupp API with compiler-emitted SPIR-V and compare the
# GPU result against the AOT CPU body emitted from the same source.
bench=$root/bench/wgpu-spike
(
    cd "$bench"
    "$root/bin/nupp" build --target typed
)

luajit=$($root/scripts/toolchain luajit)/bin/luajit
typed=$bench/build/typed
lua_root=$(cygpath -m "$root")
lua_typed=$(cygpath -m "$typed")
export LUA_PATH="$lua_typed/?.lua;$lua_typed/?/init.lua;$lua_root/build/?.lua;$lua_root/.rocks/share/lua/5.1/?.lua;$lua_root/.rocks/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$lua_root/.rocks/lib/lua/5.1/?.dll;;"
export NUPP_NATIVE_LIBRARY="$lua_typed/lib/nupp_native"
NUPP_WGPU_LIBRARY=$("$root/scripts/toolchain" wgpu)
export NUPP_WGPU_LIBRARY
export GEMM_M=64 GEMM_N=64 GEMM_K=64

"$luajit" "$bench/counted-api.lua"
# Validate and execute the peer WGSL route with the same independent oracle.
wgsl=$typed/counted-wgsl
mkdir -p "$wgsl"
for kernel in literal boundaries snapshots control; do
    "$root/bin/nupp" aot --emit wgsl --triple wasm32-unknown-emscripten \
        --function "$kernel" "$bench/typed/counted.nupp" > "$wgsl/$kernel.wgsl"
done
"$luajit" "$bench/counted-wgsl.lua" "$(cygpath -m "$wgsl")"
"$luajit" "$bench/gemm-api.lua"
