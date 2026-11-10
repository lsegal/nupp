//! Nupp's AOT code generator: LLVM and lld, linked into the host.
//!
//! The compiler (written in Nupp) lowers its AOT IR to LLVM IR text. This crate
//! knows nothing about Nupp: it parses that text, verifies it, runs LLVM's
//! optimization pipeline, generates an object for the requested target, and links
//! with lld. Option parsing, the numeric-contract checks over the optimized IR
//! and assembly, the report and link-kit unpacking are the compiler's, in
//! Nupp. Built without the `llvm` feature it compiles anywhere and every entry
//! point reports that it carries no code generator.

#![forbid(unsafe_op_in_unsafe_fn)]

mod isolated;
pub mod kit;
pub use isolated::{Job, compile_files};
#[cfg(nupp_llvm)]
mod llvm;

/// The code generator's identity: part of every AOT cache key.
pub const CODEGEN_VERSION: u32 = 1;

/// What a compile is for. `triple` is the LLVM code-generation triple (never
/// a public Nupp platform name); `cpu` and `features` are the module's
/// baseline, which per-function `"target-cpu"`/`"target-features"` attributes
/// override for tiered functions.
#[derive(Clone, Debug, Default)]
pub struct CompileOptions {
    pub triple: String,
    pub cpu: String,
    pub features: String,
    /// 0-3: `default<O0>` .. `default<O3>`, and the matching code-generation
    /// level.
    pub opt: u8,
    /// Also return the assembly listing (a second code generation).
    pub assembly: bool,
    /// Also return the optimized IR.
    pub optimized_ir: bool,
}

/// Microseconds spent in each phase of one compile.
#[derive(Clone, Copy, Debug, Default)]
pub struct Timings {
    pub parse: f64,
    pub optimize: f64,
    pub codegen: f64,
}

impl Timings {
    /// The three phases in microseconds, space-separated, for the compiler to
    /// report.
    pub fn text(&self) -> String {
        format!("{} {} {}", self.parse, self.optimize, self.codegen)
    }
}

#[derive(Clone, Debug, Default)]
pub struct Compiled {
    pub object: Vec<u8>,
    pub assembly: Option<String>,
    pub optimized_ir: Option<String>,
    pub timings: Timings,
}

/// Whether this build carries LLVM.
pub fn available() -> bool {
    cfg!(nupp_llvm)
}

/// `"llvm <version>; codegen <n>"`, or a statement that there is none.
pub fn version() -> String {
    #[cfg(nupp_llvm)]
    {
        llvm::version()
    }
    #[cfg(not(nupp_llvm))]
    {
        format!("none; codegen {CODEGEN_VERSION}")
    }
}

#[cfg(not(nupp_llvm))]
const UNAVAILABLE: &str = "this nupp was built without the LLVM code generator (scripts/toolchain llvm, then rebuild with the codegen feature)";

/// Compiles one module of LLVM IR text to an object.
pub fn compile(ir: &str, name: &str, options: &CompileOptions) -> Result<Compiled, String> {
    #[cfg(nupp_llvm)]
    {
        llvm::compile(ir, name, options)
    }
    #[cfg(not(nupp_llvm))]
    {
        let _ = (ir, name, options);
        Err(UNAVAILABLE.into())
    }
}

/// Whether a link left this process unable to exit through its static
/// destructors, which on a Windows host an ELF, Mach-O or Wasm link does.
pub fn unexitable() -> bool {
    #[cfg(nupp_llvm)]
    {
        llvm::unexitable()
    }
    #[cfg(not(nupp_llvm))]
    {
        false
    }
}

/// Ends the process with `code` once the C streams are flushed, without its
/// static destructors.
pub fn end_process(code: i32) -> ! {
    #[cfg(nupp_llvm)]
    {
        llvm::end_process(code)
    }
    #[cfg(not(nupp_llvm))]
    {
        std::process::exit(code)
    }
}

/// Runs lld in process. `argv[0]` picks the flavor: `ld64.lld`, `ld.lld`,
/// `lld-link`, `wasm-ld`. Returns lld's output (warnings) on success.
pub fn link(argv: &[String]) -> Result<String, String> {
    #[cfg(nupp_llvm)]
    {
        llvm::link(argv)
    }
    #[cfg(not(nupp_llvm))]
    {
        let _ = argv;
        Err(UNAVAILABLE.into())
    }
}

/// Writes a MinGW import library naming `dll` as the provider of each name;
/// a non-empty rename imports the name under that export instead.
pub fn import_library(dll: &str, path: &str, names: &[(String, String)]) -> Result<(), String> {
    #[cfg(nupp_llvm)]
    {
        llvm::import_library(dll, path, names)
    }
    #[cfg(not(nupp_llvm))]
    {
        let _ = (dll, path, names);
        Err(UNAVAILABLE.into())
    }
}

/// Writes the static archive `path` of `members`, indexed, in format `kind`:
/// 0 GNU, 1 BSD, 2 Darwin, 3 COFF.
pub fn archive(path: &str, members: &[String], kind: i32) -> Result<(), String> {
    #[cfg(nupp_llvm)]
    {
        llvm::archive(path, members, kind)
    }
    #[cfg(not(nupp_llvm))]
    {
        let _ = (path, members, kind);
        Err(UNAVAILABLE.into())
    }
}
