# Changelog

## Unreleased

- A parallel cold `nupp build` writes the same reflection descriptors as a
  serial one. A worker that imported a record with a `@private` field said it
  needed no factory, and a serial build described a generic record's methods
  as they were before their module finished checking, so the two disagreed on
  `requiresFactory`, `noYield` and the descriptor fingerprint.
- `nupp test` runs the shared lane's eight workers at once, each in a Lua state
  of its own that is replaced once its heap passes 256 MB
  (`NUPP_TEST_WORKER_HEAP_MB`). The workers used to share a pool as wide as
  the machine's cores, so a 3-core runner ran three. Each of those states kept
  what every suite it ran left behind. Where each worker has less than 1.5 GB
  of memory, its states also collect garbage sooner. On the 7 GB macOS CI
  runner, this repository's shared lane went from about 10,350 s to about
  1,300 s, and peak memory fell from more than the runner holds to 3.5 GB.
- `nupp bc --json`'s `bytecodeFingerprint`, and `nupp lsp artifact --kind
  bytecode`'s `metadata.fingerprint`, are now the same on every run over the
  same source. They hashed LuaJIT's raw dump, which lays out constant tables
  by a string hash LuaJIT seeds per process, so the same bytecode could get a
  different fingerprint each run.
- `nupp bc`, `nupp run` and `nupp lsp artifact` of a file inside a project keep
  the checked interfaces of the project modules it requires in the build
  directory, and read them back on the next command instead of checking the
  whole import graph from source again. A module is read back only while its
  source, what it requires, and the project's declarations are unchanged. In
  the compiler's own checkout, `nupp bc -O1 bench/aos.bench.nupp` went from
  about 515 MB and 17 s to 157 MB and 6 s on Windows once warm, and `nupp lsp
  artifact` of the same file from about 905 MB to 158 MB.
  `NUPP_NO_INTERFACE_CACHE` turns the store off.
- `nupp test` workers no longer keep every type of every project their tests
  compiled. A test that builds a project in each of its cases used to add
  about 45 MB to its worker per build, so a suite of them could peak past
  2 GB; the worker now stays near what one build needs.
- `nupp test` runs each suite that starts processes in a fresh worker
  process, as it already did for isolated suites. Each worker used to keep
  one process for every suite it took and kept growing. In this repository's
  suite, eight such workers exhausted a 16 GB Linux CI runner partway through.
- A native compile that `require`s a standard-library module keeps the checked
  interfaces in its cache and reads them back on the next command, instead of
  checking the module's whole graph from source every time. `nupp run` of a
  program that requires `serde.json` went from about 300 MB and 24 s to about
  110 MB and 5 s on Windows once warm. `NUPP_NO_STDLIB_CACHE` turns the cache
  off.
- A cold `nupp build` of a project that declares a const-generic function no
  longer starts parallel check workers it then discards. The build used to
  start up to six workers, have them parse every source, and only then decide
  to build in one process; it now decides before starting any.
- A cold `nupp build` of a project that declares a const-generic function
  runs on the parallel checker. The build plans its const specializations
  first and hands the plan to the workers, so what it writes matches the
  serial build byte for byte. It used to build such a project in one process.
- A parallel `nupp check` or `nupp build` no longer reports a const parameter
  as unbound where a module leaves out an argument another module's alias
  gives a default, such as `span.Span<uint8>`.
- The parallel checker no longer falls back to checking serially when a
  module reads a builtin a project implements, such as `io`, `os` or
  `assert`, names a type of a module it does not require, or reaches a
  project module through one the target does not check as its own.
- Sending a large string to a child process, as `stdin:send` does, no longer
  copies the unsent rest on every write. A few megabytes sent through a pipe
  made gigabytes of short-lived garbage.
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
  once its module is generated, and the same build peaks under 1 GB. Types
  nothing references any more are let go of too, rather than kept for the life
  of the process, which takes that build from about 800 MB to about 700 MB.
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
