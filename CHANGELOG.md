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
