# Changelog

## Unreleased

- A cold `nupp build` of a project that declares a const-generic function no
  longer starts parallel check workers it then discards. The build used to
  start up to six workers, have them parse every source, and only then decide
  to build in one process; it now decides before starting any.
- On ARM64, a 64-bit shift by a 64-bit constant count, such as
  `x ~ (x << 1ULL)`, keeps its count once LuaJIT traces it. The traced code
  shifted by zero instead, so `math.u64.prefixxor(1)` could answer `0ULL` on
  Apple silicon and ARM64 Linux.
- `nupp test` starts at least eight workers by default, one per processor on
  machines with more. A four-core machine used to run four suites at once and
  now runs eight. `--jobs=N` still sets the count explicitly.
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
- `nupp build` and `nupp check` use a fraction of the memory they did. A build
  kept every module's checked syntax tree until it finished, so a cold build of
  this repository's test runner peaked at 4 to 6 GB; each tree is now let go
  once its module is generated, and the same build peaks under 1 GB.
  `nupp build --json` reports the build's peak in `timing.peakBytes`.
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
- Every `nupp` process appends its peak resident memory and its arguments to
  the file `NUPP_PEAK_MEMORY_FILE` names, when it is set.
- On Windows, the first progress line of a build is no longer dropped when the
  build starts early in its process.
