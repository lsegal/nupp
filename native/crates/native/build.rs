//! Links the AOT runtime into the provider when one is named.
//!
//! The runtime is a Nupp native program (`native/aotruntime`): the value-stream
//! builder LLVM-compiled Lua-builder entries call, reached through the table
//! `nuppAotRuntime` returns. It is compiled to a static archive by the Nupp
//! compiler, which itself needs this provider to run, so the first provider a
//! checkout builds has no runtime: `scripts/toolchain` builds the archive
//! with the compiler that provider made possible and builds the provider
//! again with `NUPP_AOT_RUNTIME_ARCHIVE` naming it. Without it,
//! `nuppAotRuntime` is absent and the feature bit says so.
//!
//! The runtime calls the Lua C API, which the process loading this crate
//! provides: statically in `nupp`, and through the interpreter when this is the
//! provider library. It imports none of it: a host that links LuaJIT privately
//! exports no Lua API, and a Windows import has to name a module, so the
//! runtime finds the API in the process itself the first time it is asked for
//! (`ks_rt_bind`), and the provider loads wherever Lua is not exported.

use std::path::Path;

fn main() {
    println!("cargo:rerun-if-env-changed=NUPP_AOT_RUNTIME_ARCHIVE");
    println!("cargo::rustc-check-cfg=cfg(nupp_aot_runtime)");
    let Some(archive) = std::env::var_os("NUPP_AOT_RUNTIME_ARCHIVE").filter(|value| !value.is_empty()) else {
        return;
    };
    let archive = Path::new(&archive);
    println!("cargo:rerun-if-changed={}", archive.display());
    let directory = archive.parent().expect("the runtime archive has a directory");
    let name = archive
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_prefix("lib"))
        .and_then(|name| name.strip_suffix(".a"))
        .expect("the runtime archive is named lib<name>.a");
    println!("cargo:rustc-link-search=native={}", directory.display());
    println!("cargo:rustc-link-lib=static={name}");
    println!("cargo:rustc-cfg=nupp_aot_runtime");
}
