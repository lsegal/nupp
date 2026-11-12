---
order: 710
title: Native runtime and support
---

# Native runtime and support

Nupp source and the Nupp compiler own language behavior, and since the Rust
workspace was removed they own the native runtime as well: the providers, the
executable host, the embedding SDK and the AOT code generator's driver are all
Nupp. A native build does not translate a Nupp program into some other
language's application. The compiler still emits Lua, C AOT code, or GPU
shader code, and Nupp modules that call the operating system through LuaJIT's
FFI, or native Nupp programs compiled by the checkout's own compiler, supply
the mechanisms that code reaches.

The boundary is deliberately narrow:

| Layer | Owner | Responsibilities |
| --- | --- | --- |
| language and compiler | Nupp | types, effects, ownership, suspension policy, feature selection, AOT analysis and emission, driving LLVM and lld as the AOT code generator, the filesystem, process, network, TLS and HTTP services, which call the operating system through FFI, URI parsing with its UTS #46 host mapping, clocks, UUIDs, and the readiness generation and its wake handle |
| native provider | Nupp, a native program | the provider ABI's version and feature bits, its error slot, byte copies, the machine's parallelism, and the AOT runtime's table |
| GPU provider | Nupp | GPU contexts, resources, validation, dispatch, readback, and cost records, over the pinned wgpu-native library |
| host and embedding SDK | Nupp, native programs | payload discovery, LuaJIT state lifetime, native preload registration, workers, channels, shared bytes, components, embedding handles, and shutdown |
| VM and compatibility modules | C, upstream | LuaJIT and the retained LPeg module |
| generated AOT | C, platform object code, or shader code | compiler-admitted kernels and their bindings |

Native resources cross into LuaJIT as fixed-width values and generational
handles, and no thread a native program starts enters a Lua state it does not
own.

## Former Rust crates

Each crate that used to live under `native/crates/` was ported to Nupp and
deleted, along with the Cargo workspace, its lockfile and the pinned Rust
toolchain. What replaced each one:

| Former crate | Nupp implementation | Notes |
| --- | --- | --- |
| `abi` | `native/abi/nuppnative.nupp` | the provider ABI's definition; `scripts/native-abi-header` generates the C header from it |
| `checksum` | `nupp.checksum` (`src/nupp/checksum`) | table-driven CRC-32 and CRC-64, with no native artifact |
| `compression` | `nupp.compression` (`deflate`, `inflate`) and `nupp.runtime.provider.nativecompression` | DEFLATE, zlib and gzip framing |
| `files` | `nupp.runtime.provider.nativefiles`, with `nativefsposix`, `nativefswindows`, `nativefsglob` and `nativefslane` | files, directories, globbing and bounded whole-file transfers through FFI |
| `platform` | `nupp.runtime.provider.nativeplatform` | clocks, sleeping and system randomness through FFI, and the UUIDs built from them |
| `process` | `nupp.runtime.provider.nativeprocess` | spawning, pipes, reaping and waiting through FFI |
| `net` | `nupp.runtime.provider.nativesocket` and `nativenet` | TCP, UDP, DNS and Unix path sockets from a reactor that runs no thread |
| `http` | `nupp.io.http` and `nupp.runtime.provider.nativehttp` | the HTTP/1.1 client, pooling, proxies and content decoding |
| `tls` | `nupp.io.tls` and `nupp.runtime.provider.nativetls` | TLS 1.2 and 1.3 and their cryptography |
| `gpu` | `nupp.runtime.provider.gpudevice`, `gpucosts` and `wgpu` | the GPU provider and cost model over wgpu-native |
| `runtime` | `nupp.runtime.native` | the readiness generation and the wake handle |
| `host` | `host/program` | the executable host, its workers, channels, shared bytes and payload loader, and the C embedding SDK (`libnupp`, `host/program/common/nuppembed`) |
| `codegen` | `nupp.compiler.aot.llvm.codegen` | drives LLVM and lld through FFI; the names the code generator library exports are listed in `native/codegen/symbols` |
| `native` | `native/provider`, with `native/aotruntime` compiled in | the aggregate provider library, `nupp_native` |

The C shims that supported the Rust host -- its protected LuaJIT boundary,
the worker shim, the AOT runtime's `ks_rt.c`, and the browser guest's
`guest-*.c` -- went with it; their work is in the Nupp programs above.
`codegen`'s `glue.cpp` was the last first-party C++.

## Compiler-selected features

Authors select APIs, not provider features. The compiler records effects from
the reachable program and closes their dependencies. The build then asks
`scripts/toolchain` for an exact-feature provider and host, and a program that
reaches no facility needing them stages neither. A GPU-free program stages no
wgpu-native library.

| Nupp facility | Provider feature | Host feature when linked into a stub |
| --- | --- | --- |
| AOT runtime for LLVM-compiled builders | `base` | provider archive |
| clocks and timer suspension | none: Nupp reads the platform clocks through FFI | base host |
| paths and files | none: Nupp calls the operating system through FFI | none |
| UUID | none: Nupp over the platform clock and randomness | none |
| URI | none: the URL Standard's parser and UTS #46 in Nupp | none |
| HTTP client | none: HTTP/1.1 in Nupp over the network and TLS services | none |
| TCP, UDP, DNS, and Unix path sockets | none: Nupp sockets through FFI | none |
| TLS over a network stream | none: TLS 1.2/1.3 and its cryptography in Nupp | none |
| child processes and pipes | none: Nupp spawns, reaps and waits through FFI | none |
| native GPU compute | none: Nupp over wgpu-native | none: `lib/wgpu_native` beside the program |
| workers and shared immutable bytes | host-owned | `workers` |
| `lpeg` | retained LPeg | `lpeg` |

TLS includes the network service, and the compiler's HTTP effect closure also
selects TLS, the network service and URI handling. Sockets, TLS and processes
wait on the runtime's wake handle, which is Nupp too, and URI handling is Nupp,
so none of them, HTTP included, stages the provider. The `native-net`, `native-process` and `native-tls` host
features remain as names that select nothing, so manifests and release feature
lists naming them keep working. A standalone link may combine the host's
application archive with the provider's archive. Shared sidecar builds stage
the same provider ABI in a dynamic library instead.

The provider's ABI version 2 is an internal compiler/runtime boundary. It is
not an extension ABI for applications. The public C embedding API in
`host/include/nupp.h` has its own version and opaque types; its implementation
is a native Nupp program even though C and C++ applications call it.

### Provider ABI evolution

The provider has one consumer built from a different checkout: the pinned
stage-zero compiler. A fresh checkout's first build runs the previous release's
compiler against the pinned prebuilt provider, and later ones (`nupp fixpoint`
included) against the provider this checkout built. That compiler requires
version 2 exactly. Every other caller is built from the same checkout as the
provider. So the version stays at 2, and the ABI grows by addition:

- A minor change never renumbers. It adds exports, a feature bit, or an enum
  value an older caller never receives. It does not change a signature, a
  struct layout, or the meaning of a status or state value in place.
- A replacement is named for the capability it adds, never with a version
  suffix.
- A new struct that crosses by pointer starts with `uint32_t size`, which the
  caller sets to the size it was compiled with. The provider refuses a size
  smaller than the struct's first version and touches only the fields it knows,
  so the struct can grow at its tail.
- A symbol can be deleted once no provider module uses it and the pinned
  stage-zero bundle does not name it. `rustabitest` checks that every
  `nuppNative*` name in the pinned bundle is still declared in the ABI's
  definition, `native/abi/nuppnative.nupp`, and that its version is the one
  the bundle requires. The C header is generated from that definition by
  `scripts/native-abi-header`, and `rustabitest` compiles it and calls the
  provider through it.
- Status codes and their meanings are part of the ABI. `nuppNativeBytesCopy`
  still returns `CAPACITY` for a short output, where every other call returns
  `BUFFER_TOO_SMALL`, because the pinned bundle reads that code as the answer
  to its size probe.
- A major bump takes two releases. The first ships a loader that accepts both
  versions, the stage-zero pin moves to it, and only then does the provider
  bump.

`NUPP_NATIVE_INTERNAL` remains a status in the ABI for compatibility, though
the Nupp provider has no panic for it to report.

### Readiness

`nupp.runtime.native` keeps one readiness generation per Lua state, which a
family advances with `native.advance` when something a caller could be waiting
for changes. A family snapshots it first, checks what it is waiting for with
non-blocking calls, and sleeps from the snapshot, so an edge after the snapshot
ends the sleep at once and none is lost. One snapshot serves every family in a
pass.

The families -- sockets, TLS and HTTP, processes and their pipes -- run on the
state's own thread. Each sleeps in one `poll` (`WSAPoll` or
`WaitForMultipleObjects` on Windows) over its own handles and the state's wake
handle, a manual-reset event on Windows and a pipe elsewhere that every advance
signals. A scheduler polling every source between bounded waits therefore sees
whichever family moves first. GPU `synchronize` is the exception:
wgpu-native reports finished work only when asked, so its readiness source
polls the device and sleeps one bounded slice between polls. It is still a
suspension, so a task deadline reaches the wait and other tasks run meanwhile.

The provider has no readiness calls. Its `nuppNativePoll`, `nuppNativeWait`,
`nuppNativeWakeOpen` and `nuppNativeWakeClose`, and the per-family poll and
wait calls that came before them, were removed once stage zero was repinned to
a compiler whose runtime keeps readiness in Nupp.

## Native implementations

The current implementation choices are:

- wgpu-native owns GPU device discovery, resources, command submission, and
  backend selection, behind its C API. `nupp.runtime.provider.gpudevice` is the
  Nupp layer over it, reached through LuaJIT's FFI: handle tables, range and
  alignment checks, SPIR-V workgroup checks, downloads, timestamps and cost
  records. `scripts/toolchain wgpu` fetches the prebuilt library for each
  platform against a digest in `scripts/toolchain.pins`; it uses Metal on macOS,
  DX12 and Vulkan on Windows, and Vulkan and GLES on other Unix systems, and
  `WGPU_BACKEND` narrows the choice.
- Nupp owns sockets and name resolution (`nupp.runtime.provider.nativesocket`
  and `nativenet`), calling BSD sockets or Winsock through LuaJIT's FFI from a
  reactor that never runs a thread.
- Nupp owns TLS 1.2 and 1.3 and their cryptography (`nupp.io.tls`): AES-GCM,
  ChaCha20-Poly1305, X25519, P-256 and P-384, RSA and Ed25519, and X.509 path
  validation with webpki's rules. Default trust anchors come from
  `SSL_CERT_FILE`/`SSL_CERT_DIR`, the Windows certificate stores (asking the
  Windows chain engine for a root it has not delivered yet), or the system
  bundle file. It is not constant time.
- Nupp owns the HTTP/1.1 client, connection pooling, streaming, HTTP and SOCKS5
  proxies, and gzip and deflate decoding, over those sockets and TLS.
- The native provider itself is a Nupp native program (`native/provider`):
  the ABI's version and feature bits, its error slot, the machine's
  parallelism, and the AOT runtime's table, with the runtime compiled in.
  `scripts/toolchain native-provider` builds it with the checkout's compiler;
  before there is one, the checkout runs on the pinned prebuilt provider.
- The host and the embedding SDK are native Nupp programs under
  `host/program`, one per operating system over shared `common` modules, and
  call the platform's own libraries directly.

These libraries are implementation details. The Nupp modules define the public
contracts and may intentionally expose less than the underlying library.

## Retained foreign boundary

No first-party native mechanism is written in Rust, C++ or C. That is not a
claim that every executable byte is Nupp. Native builds still retain:

- pinned LuaJIT, its allocator, garbage collector, JIT, stack, and C API;
- LPeg 1.1 for `lpeg` compatibility and compiler documentation parsing;
- compiled AOT code. The AOT runtime a builder entry calls, through a table the
  provider hands it, is a native Nupp program (`native/aotruntime`) that
  `scripts/toolchain` compiles with the checkout's own compiler and links into
  the provider, so the first provider a checkout builds, before it has a
  compiler, has none;
- LLVM and lld, the AOT code generator, linked into `nupp` (or, in a source
  checkout, into the code generator library beside its provider) and never into
  the programs it builds;
- the pinned, prebuilt wgpu-native library, which a GPU program loads beside
  itself;
- operating-system libraries, GPU drivers, and platform SDKs selected by the
  host programs and the final linker.

LuaJIT, LPeg and LLVM are upstream projects fetched at pinned digests, not
source in this tree. A checkout builds LuaJIT and LPeg with the machine's C
compiler when it does not already have them, and builds LLVM with a C++
compiler only when no prebuilt code generator is pinned for its platform; see
[`CONTRIBUTING.md`](https://github.com/nupp-lang/nupp/blob/main/CONTRIBUTING.md#requirements).

The release notices describe the exact third-party source carried by a host.
Software Vulkan used by CI is external test infrastructure, not the production
GPU ownership layer.

## Release support matrix

The official release workflow builds these compiler hosts and catalog stubs:

| Public target | Release archive | Link kit | Host build ABI |
| --- | --- | --- | --- |
| `x86_64-unknown-linux-gnu` | `nupp-linux-x86_64.tar.gz` | `nupp-kit-x86_64-unknown-linux-gnu.tar.gz` | native Linux GNU |
| `aarch64-apple-darwin` | `nupp-macos-arm64.tar.gz` | `nupp-kit-aarch64-apple-darwin.tar.gz` | native Apple Darwin |
| `x86_64-pc-windows-msvc` | `nupp-windows-x86_64.zip` | not yet published | GNU |

The Windows names describe two different contracts. Nupp's AOT artifacts use
the public `x86_64-pc-windows-msvc` target name and layout, and LLVM
compiles them for `x86_64-w64-windows-gnu`.
The Nupp host itself embeds a LuaJIT built by its GNU make and MinGW toolchain,
so the host program links against the MinGW ABI too.

The release workflow also publishes the browser runtime separately. Browser
Lua and WebGPU use their own portable host and do not turn the desktop host
matrix into a browser support promise.

### Verification ownership

The compiler CI matrix runs the Nupp suite on Linux x86-64, macOS arm64, and
Windows x86-64. Before that broad suite, each runner crosses the aggregate C
ABI and links and runs the production executable host, static application
archive, and static and dynamic embedding SDKs. Release builders repeat that
artifact gate on the runner whose output they package because a separate
compiler workflow cannot be a dependency of a tagged release. They then stamp,
package, unpack, and run the matching compiler hosts, and build each platform's
link kit. Cross-target jobs stamp all three public targets and execute each
result on its matching runner, and a standalone AOT program linked on one
platform from another's kit runs on that other platform. A separate gate fails
the build if Rust or C++ source returns to first-party code.

Those workflows are the platform gates; their presence alone is not evidence
that a particular commit completed them. The Nupp host is exercised on the
retained Linux, macOS, and Windows runners, including the executable host,
static application host, static and dynamic embedding SDKs, workers, appended
compiler payloads, unpacked release artifacts, and byte-identical compiler and
binary packaging fixpoints. The Windows gate also exercises the DirectX 12
wgpu-native adapter rather than relying only on the cross-platform software adapter.
Manual release rehearsals do not hold Apple Developer ID credentials and cannot
exercise optional tag-only signing and notarization. The same release matrix
still builds and verifies an unsigned macOS archive without those credentials.

## Migration breaks

The native cutovers intentionally did not preserve every old native API or
artifact:

- The legacy provider ABI and its C implementation were removed. The compiler
  and runtime now select the version-2 provider only.
- The production C host under `host/c` was removed in favour of a Rust host,
  which was later replaced in turn by the native Nupp programs in
  `host/program`. The C embedding header remained through both moves, so
  existing hosts migrate at the SDK boundary.
- The Rust embedding crate, `native/crates/host`, and its C shims were
  replaced by a native Nupp program, `host/program/common/nuppembed`.
  `nupp.h`, embedding ABI 2, `libnupp`'s file names and its export list are
  unchanged, so a host relinks without source changes.
- The Rust provider crate, `native/crates/native`, was replaced by the native
  Nupp program `native/provider`. Provider ABI 2 and its feature bits are
  unchanged.
- The Cargo workspace, `Cargo.lock`, `rust-toolchain.toml` and `.cargo/` were
  deleted, with Rust provisioning and Rust output caching in
  `scripts/toolchain` and `bin/nupp`. `NUPP_RUSTC`, `NUPP_CARGO`,
  `NUPP_RUST_BUILD_DIR` and `NUPP_RUST_VENDOR_DIR` no longer mean anything to
  the build, and `scripts/toolchain native-rust` and `rust-vendor` are gone. A
  project's own [Rust dependencies](../learn/projects/build.md#rust-dependencies)
  still build with the project's Cargo.
- SDL GPU, SPIRV-Cross, MSL artifacts, and the SDL provider ABI were removed.
  Native GPU builds accept canonical SPIR-V and execute it through wgpu-native.
- The Rust GPU crate, its `nuppNativeGpu*` provider exports, the
  `NUPP_NATIVE_FEATURE_GPU` bit and the `native-gpu` host feature were removed.
  The GPU provider is Nupp over wgpu-native, staged beside a program, so a
  standalone binary cannot carry it.
- Curl and ada were removed. URI behavior follows Rust's WHATWG `url` contract,
  and HTTP follows the documented Reqwest contract rather than curl parity.
- URI parsing later moved off the provider's `url` crate to Nupp: the URL
  Standard's parser, with UTS #46 tables generated from the Unicode Character
  Database by `scripts/idna-tables`, giving the crate's results and refusal
  reasons. The provider's `uri` feature, its `nuppNativeUri*` exports and
  the `NUPP_NATIVE_FEATURE_URI` bit are gone.
- Libuv and mbedTLS were removed, and later the Rust `net`, `http` and `tls`
  crates, with Tokio's network lanes, Reqwest and Rustls. Sockets, TLS and HTTP
  are Nupp over FFI; their `nuppNativeNet*`, `nuppNativeTls*` and
  `nuppNativeHttp*` exports and the `NET`, `TLS`, `HTTP` and
  `NET_ENDPOINT` feature bits are gone. HTTP/2 was never selected and is
  not offered. DTLS, kTLS, the old public session-ID and
  ticket-key controls, and Windows named-pipe emulation of Unix path streams
  are not part of the retained contract.
- File and process resources moved behind Rust ownership, and later to Nupp
  over FFI. Cancellation and close semantics preserve the accepted Nupp state
  machines, but undocumented C handles and backend functions are not
  compatibility surfaces.
- The LLVM code generator crate and its `glue.cpp` were replaced by
  `nupp.compiler.aot.llvm.codegen`, which drives LLVM and lld in process
  through FFI. The provider's `codegen` feature and the embedding SDK's
  `native-codegen` feature are gone.

Code which used public Nupp modules should migrate to their current documented
contracts. Code which loaded a provider directly, relied on SDL or curl
behavior, or linked files from the deleted C host must move to the compiler-
selected provider or the public embedding SDK. There is no compatibility mode
which restores the old ownership model.
