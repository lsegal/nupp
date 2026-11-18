# Changelog

## Unreleased

- The first command against an empty cache now keeps the standard-library
  interfaces it checked, and a project's own, as well as the prelude. Before,
  only the next command could keep them, so a fresh cache paid for checking
  the standard library from source twice: requiring `serde.json` cost about
  five seconds on each of the first two commands, and now costs that once and
  about one second after.

- Compiler and tool stamps use the native digest whenever the caller names
  none, instead of the portable one. The answers are the same; the portable
  digest spent seconds over the whole compiler tree, which an AOT build paid
  for its tool stamp.

- A process that builds several environments, such as a `nupp test` run with
  its suites in one process, no longer checks the prelude and the standard
  library again for each of them. Environments that agree on the target,
  compat and lints share one checked prelude, and the standard-library modules
  checked against it unless a project shadows one. A later environment now
  takes about 2 ms instead of 380, and requiring `simd` or `serde.json`
  again checks in tens of milliseconds instead of 8 to 18 seconds.
  `NUPP_NO_SHARED_PRELUDE` turns the sharing off.

- A binary built beside the compiler's own build carries every module whose
  source is the one the compiler was built from, byte-for-byte, instead of
  compiling it again. The repository's test runner went from 610 compiled
  modules to 75, and its cold build from about 104 to 63 seconds on Linux.
  Coverage builds and checks still compile everything.

- Diagnostics reported at the same position now keep the order they were
  reported in. Before, the sort could swap them, so which of two came first
  depended on where it happened to move them.

- An incremental build no longer rechecks `debug.log` after every edit. A
  compiler source staged only to be checked against has no build record, so
  every module depending on it was treated as having a changed dependency.

- `nupp fmt` type-checks a file only when one of its paths could become an
  import. Before, nearly every file was checked, along with every module it
  reached, so formatting a cold project cost about as much as checking all of
  it. A cold `nupp fmt --check` over a quarter of this repository went from
  about 250 seconds to about 30 on Windows, with the same results.

- Two worker lanes of one process that link native code at the same time no
  longer corrupt each other. lld runs in process and keeps its state in
  process globals, so overlapping links freed each other's state, failed with
  "lld stopped with status 1 and no message", or crashed the process with an
  access violation. Links, LLVM target setup and the POSIX compile fork now
  take one lock for the whole process.

- On Windows, a `nupp test` worker no longer dies with `cannot retire a
  claimed test queue piece`, which left every suite it would have run
  reported as `<unrun>`. The run's own progress check held queue pieces open,
  so a worker that had already claimed one could fail to remove it. Workers
  now run a claimed piece whether or not its file could be removed, and the
  run counts what is left by the claims rather than by the pieces.

- `nupp fixpoint` now also holds the compiler's native half to the fixpoint:
  stages two and three each lower the native provider, the host and the
  embedding library to LLVM IR, which must match, and each runs on the
  provider the stage before it linked. `--json` reports them as `native` and
  `nativeRelinked`.

- When a record's method is defined in a module other than the one that
  declares it, other modules now always see the declared signature. Before,
  modules checked after the defining module saw the definition's signature
  instead. That dropped what only the declaration said, such as `borrows
  self`, and gave a false `NUPP2619` that depended on check order. A parallel
  check of `bench/native-runtime` reported it now and then in
  `bytes.nupp`.

- On Windows, a child process dropped while still running, such as the
  comptime worker a compiler command starts in the project, is waited for
  after it is terminated. Removing the project directory right after the
  command no longer fails with "being used by another process (os error 32)".

- A parallel `nupp check` or `nupp build` no longer reports errors a serial
  one does not where one module uses what another declared: a prelude record
  such as `types.reflect.Info` in its API (`Info is not a Info`), a C type
  its literal `ffi.cdef` block declared (`not a C type`), or an interface
  overload whose default body an implementing record inherits (`does not
  implement overload`). A cold parallel check of `bench/native-runtime`
  reported 13 to 51 such errors.

- `build/.nupp-state.json` is the same, byte for byte apart from derive
  timings, whether a cold `nupp build` checked serially or on the parallel
  checker, and from one build to the next. The file is written with sorted
  keys. A call fact read inside an import cycle is read again once the cycle
  has closed, instead of keeping the empty answer for the rest of the build. A
  re-exported or aliased record is described by the module that declares it,
  and an alias no longer renames that record for other modules. Effect
  analysis no longer reads another module's in-process records, and a
  parameter assigned to another parameter is always named for the first.
  Before, the state differed in up to fifteen module records depending on
  the schedule.

- A parallel cold `nupp build` writes the same Lua as a serial one. A worker
  that imported a record with a `@private` field said it needed no factory; a
  serial build described a generic record's instances as they were before
  their module finished checking; and in an `@!internal` module, a method
  declared above a type it takes got a different overload member name
  depending on whether that module had been imported first.
- `nupp build` of a binary target copies the host into the stamped binary a
  block at a time instead of reading it into memory and copying it there. A
  host that links LLVM in is about 140 MB, and holding it twice put
  170-830 MB on the build's peak. A cold build of this repository's test
  runner with the pinned LLVM went from 1.15 GB to about 800 MB on Windows,
  from 1.55 GB to about 720 MB on macOS, and from 890 MB to about 720 MB on
  Linux.
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
- Outside macOS, `nupp`, the native host and the embedding SDK give LuaJIT
  machine-code areas of 512 KB, chained up to the same 16 MB, instead of one
  16 MB area. LuaJIT reprotects a whole area around every trace it compiles,
  and with several busy states in one process those calls queued on the
  kernel's address-space lock. On the 4-core Linux CI runner the shared test
  lane's kernel time fell from 23-41% of its CPU to about 7%, and it finished
  in 563-611 s where it had taken 580-1,002 s. macOS keeps its one area, which
  works around the system ignoring LuaJIT's placement hint.
- `nupp bc`, `nupp run` and `nupp lsp artifact` of a file in a project nested
  inside the current one, with its own `nupp.lua`, compile it through that
  project, as the language server does. They named it by the outer project's
  roots, so a `module` declaration in the file was refused with NUPP1002.
- `nupp fmt --check` over many files keeps only the interfaces of the modules
  they require, not every module's checked tree, and collects garbage the way
  `nupp build` does. A cold check of a quarter of this repository's tree went
  from about 2 GB to about 500 MB on Windows, in the same time. `nupp check`
  of files outside a project and `nupp migrate` get the same treatment.
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
