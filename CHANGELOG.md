# Changelog

## Unreleased

- Nupp is self-hosted: building it from a checkout no longer needs Rust or a
  C++ compiler. Every crate of the former Rust workspace -- the native
  provider, the executable host and embedding SDK, the filesystem, process,
  network, TLS, HTTP, GPU and readiness services, and the LLVM code generator
  driver with its `glue.cpp` -- is now Nupp, and the Cargo workspace,
  `Cargo.lock` and `rust-toolchain.toml` are gone. `NUPP_RUSTC`, `NUPP_CARGO`,
  `NUPP_RUST_BUILD_DIR` and `NUPP_RUST_VENDOR_DIR` no longer affect the build.
  LuaJIT and LPeg are still built from their pinned upstream C sources when a
  machine lacks them, and building the pinned LLVM from source, which only a
  platform without a prebuilt code generator needs, still takes a C++
  compiler. The embedding header, embedding ABI and provider ABI are
  unchanged, so an embedding host relinks without source changes. See
  [Native runtime and support](https://nupp.dev/reference/native-runtime/)
  for which Nupp module replaced each crate.
- On Windows, `@aot` code computes `^` with the same C runtime `pow` as the
  LuaJIT that loads it, so compiled and interpreted results agree to the last
  bit. Under a MinGW LuaJIT built against `msvcrt.dll`, `0.3 ^ 3` was
  `0.026999999999999996` compiled and `0.027` in Lua. A native build on
  Windows also no longer crashes now and then while it sets up LLVM.
- `nupp test` builds the code under test in a child process, so it no longer
  holds the build's memory while the tests run. For this repository's own
  suite the command used to stay at 6 to 7 GB resident for the whole run; it
  now stays around 20 MB, leaving that memory to the test workers.
- `nupp test --coverage` probes are smaller: four bytecodes per statement or
  branch instead of six. A long function that LuaJIT refused once instrumented,
  with NUPP3005 "function too long for return fixup", now loads, which is what
  stopped coverage runs over this repository from running any tests.
- `nupp aot --emit llvm` and `--emit llvm-library` declare the C functions a
  native program calls in name order. The order used to change from run to
  run, so compiling the same source twice could give different IR.
- `nupp test` reuses recorded passes for part of a package, so a run limited
  to one lane, group or list of suites no longer re-runs a package just because
  it did not select all of it. A test policy's new `neverCache` map names
  suites that always execute, such as timing, process-lifecycle and
  measurement suites, while the rest of their package is still reused. The
  summary and the `--json` report now give the cache hit rate
  (`cacheEligiblePackages`, `cacheHitRate`) beside the cached count, and CI
  run IDs, the commit SHA and `ACTIONS_*` tokens no longer change a result's
  fingerprint, so one CI run can reuse another's passes.
- `nupp test` sizes each lane from the machine's memory as well as its cores,
  and runs shell suites each in a fresh process, so a worker no longer grows
  across suites. On this repository's suite a shell worker used to grow to 5-7
  GB, which ran a 16 GB Linux runner out of memory at two workers. It now
  stays near 100 MB, and four workers finish the Windows shell lane in about
  two thirds of the time two did.
- Every `nupp` process appends its peak resident memory and its arguments to
  the file `NUPP_PEAK_MEMORY_FILE` names, when it is set.
- On Windows, the first progress line of a build is no longer dropped when the
  build starts early in its process.
