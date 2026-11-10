//! The AOT code generator's C ABI: LLVM IR text in, objects and linked
//! artifacts out. Results are byte handles the caller copies and releases.

use nupp_native_abi::{Status, boundary, guard};
use nupp_native_codegen as codegen;

fn text<'a>(data: *const u8, length: usize, what: &str) -> Result<&'a str, i32> {
    let bytes = super::input(data, length)?;
    std::str::from_utf8(bytes)
        .map_err(|_| super::failed(Status::InvalidArgument, &format!("{what} is not UTF-8")))
}

fn output(slot: *mut u64, value: Option<Vec<u8>>) -> Result<(), i32> {
    if slot.is_null() {
        return Ok(());
    }
    let handle = match value {
        Some(bytes) => super::store_bytes(bytes)?,
        None => 0,
    };
    // SAFETY: a non-null slot is writable storage for one u64 by contract.
    unsafe { slot.write(handle) };
    Ok(())
}

fn status(result: Result<(), i32>) -> i32 {
    match result {
        Ok(()) => Status::Ok.code(),
        Err(code) => code,
    }
}

/// Compile options in the compiler's positional form, already checked there:
/// triple, cpu, features, opt (0-3), then `1` to return the assembly and `1`
/// to return the optimized IR, separated by U+001F.
fn compile_options(text: &str) -> Result<codegen::CompileOptions, i32> {
    let fields: Vec<&str> = text.split('\u{1f}').collect();
    let [triple, cpu, features, opt, assembly, optimized_ir] = fields[..] else {
        return Err(super::failed(Status::InvalidArgument, "codegen options need six fields"));
    };
    let opt = opt
        .parse()
        .ok()
        .filter(|level: &u8| *level <= 3)
        .ok_or_else(|| super::failed(Status::InvalidArgument, "codegen opt is not 0-3"))?;
    Ok(codegen::CompileOptions {
        triple: triple.to_string(),
        cpu: cpu.to_string(),
        features: features.to_string(),
        opt,
        assembly: assembly == "1",
        optimized_ir: optimized_ir == "1",
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nuppCodegenAvailable() -> u32 {
    guard(0, || codegen::available() as u32)
}

#[unsafe(no_mangle)]
/// # Safety
/// `output` must be writable storage for one u64.
pub unsafe extern "C" fn nuppCodegenVersion(result: *mut u64) -> i32 {
    boundary(|| status(output(result, Some(codegen::version().into_bytes()))))
}

#[unsafe(no_mangle)]
/// Compiles one LLVM IR module. `options` is the positional form
/// `compile_options` reads. `timings` receives the phase timings in microseconds, space-separated;
/// each other non-null output slot receives a byte handle, or 0 when that output
/// was not asked for.
///
/// # Safety
/// Each input range must be readable for its length; each non-null output
/// must be writable storage for one u64.
pub unsafe extern "C" fn nuppCodegenCompile(
    ir: *const u8,
    ir_length: usize,
    name: *const u8,
    name_length: usize,
    options: *const u8,
    options_length: usize,
    object: *mut u64,
    timings: *mut u64,
    assembly: *mut u64,
    optimized_ir: *mut u64,
) -> i32 {
    boundary(|| {
        status((|| {
            let ir = text(ir, ir_length, "LLVM IR")?;
            let name = text(name, name_length, "module name")?;
            let options = compile_options(text(options, options_length, "codegen options")?)?;
            let compiled = codegen::compile(ir, name, &options)
                .map_err(|e| super::failed(Status::InvalidArgument, &e))?;
            output(object, Some(compiled.object))?;
            output(timings, Some(compiled.timings.text().into_bytes()))?;
            output(assembly, compiled.assembly.map(String::into_bytes))?;
            output(optimized_ir, compiled.optimized_ir.map(String::into_bytes))
        })())
    })
}

#[unsafe(no_mangle)]
/// Runs lld in process over NUL-separated arguments (argv[0] picks the
/// flavor). `messages` receives lld's output on success.
///
/// # Safety
/// `argv` must be readable for `length` bytes; `messages` null or writable.
pub unsafe extern "C" fn nuppCodegenLink(
    argv: *const u8,
    length: usize,
    messages: *mut u64,
) -> i32 {
    boundary(|| {
        status((|| {
            let argv: Vec<String> = text(argv, length, "linker arguments")?
                .split('\0')
                .filter(|a| !a.is_empty())
                .map(str::to_string)
                .collect();
            let out =
                codegen::link(&argv).map_err(|e| super::failed(Status::InvalidArgument, &e))?;
            output(messages, Some(out.into_bytes()))
        })())
    })
}

#[unsafe(no_mangle)]
/// Whether a link left this process unable to exit through its static
/// destructors; 1 when it did.
pub extern "C" fn nuppCodegenUnexitable() -> i32 {
    guard(0, || i32::from(codegen::unexitable()))
}

#[unsafe(no_mangle)]
/// Ends this process with `code` without its static destructors. For a
/// process `nuppCodegenUnexitable` names, once its own output is flushed.
pub extern "C" fn nuppCodegenEndProcess(code: i32) {
    guard((), || codegen::end_process(code))
}

#[unsafe(no_mangle)]
/// Writes a MinGW import library. `names` is NUL-separated entries, each
/// `name` or `name\texport`.
///
/// # Safety
/// Each input range must be readable for its length.
pub unsafe extern "C" fn nuppCodegenImportLibrary(
    dll: *const u8,
    dll_length: usize,
    path: *const u8,
    path_length: usize,
    names: *const u8,
    names_length: usize,
) -> i32 {
    boundary(|| {
        status((|| {
            let dll = text(dll, dll_length, "DLL name")?;
            let path = text(path, path_length, "import library path")?;
            let names: Vec<(String, String)> = text(names, names_length, "import names")?
                .split('\0')
                .filter(|n| !n.is_empty())
                .map(|n| match n.split_once('\t') {
                    Some((name, export)) => (name.to_string(), export.to_string()),
                    None => (n.to_string(), String::new()),
                })
                .collect();
            codegen::import_library(dll, path, &names)
                .map_err(|e| super::failed(Status::InvalidArgument, &e))
        })())
    })
}

#[unsafe(no_mangle)]
/// Writes a static archive. `members` is NUL-separated object paths; `kind`
/// is 0 GNU, 1 BSD, 2 Darwin, 3 COFF.
///
/// # Safety
/// Each input range must be readable for its length.
pub unsafe extern "C" fn nuppCodegenArchive(
    path: *const u8,
    path_length: usize,
    members: *const u8,
    members_length: usize,
    kind: i32,
) -> i32 {
    boundary(|| {
        status((|| {
            let path = text(path, path_length, "archive path")?;
            let members: Vec<String> = text(members, members_length, "archive members")?
                .split('\0')
                .filter(|m| !m.is_empty())
                .map(str::to_string)
                .collect();
            codegen::archive(path, &members, kind)
                .map_err(|e| super::failed(Status::InvalidArgument, &e))
        })())
    })
}

#[unsafe(no_mangle)]
/// Compiles IR files to objects, `width` at a time, each isolated from this
/// process where the platform can fork. `jobs` is NUL-separated records of
/// `irPath \x1f objectPath \x1f options`; `results` receives one record per
/// job, in order, of `ok \x1f timings` or `error \x1f message`, NUL-separated.
/// A job asking for its optimized IR or assembly finds them beside its object
/// as `.ll` and `.s`.
///
/// # Safety
/// `jobs` must be readable for `length` bytes; `results` writable for one u64.
pub unsafe extern "C" fn nuppCodegenCompileFiles(
    jobs: *const u8,
    length: usize,
    width: u32,
    results: *mut u64,
) -> i32 {
    boundary(|| {
        status((|| {
            let mut parsed = Vec::new();
            for record in text(jobs, length, "compile jobs")?
                .split('\0')
                .filter(|r| !r.is_empty())
            {
                let mut fields = record.splitn(3, '\u{1f}');
                let (Some(ir), Some(object), Some(options)) =
                    (fields.next(), fields.next(), fields.next())
                else {
                    return Err(super::failed(
                        Status::InvalidArgument,
                        "a compile job needs an IR path, an object path and options",
                    ));
                };
                let options = compile_options(options)?;
                parsed.push(codegen::Job {
                    ir: ir.into(),
                    object: object.into(),
                    options,
                });
            }
            let answers = codegen::compile_files(&parsed, width as usize);
            let mut out = String::new();
            for answer in answers {
                match answer {
                    Ok(timings) => out.push_str(&format!("ok\u{1f}{timings}")),
                    Err(error) => out.push_str(&format!("error\u{1f}{error}")),
                }
                out.push('\0');
            }
            output(results, Some(out.into_bytes()))
        })())
    })
}

#[unsafe(no_mangle)]
/// Fetches a link kit archive from an HTTPS `url` into `path`, written only
/// once the whole body of `size` bytes has arrived. The compiler checks its
/// digest before unpacking it.
///
/// # Safety
/// Each input range must be readable for its length.
pub unsafe extern "C" fn nuppCodegenKitFetch(
    url: *const u8,
    url_length: usize,
    path: *const u8,
    path_length: usize,
    size: u64,
) -> i32 {
    boundary(|| {
        status((|| {
            let url = text(url, url_length, "kit URL")?;
            let path = text(path, path_length, "kit archive path")?;
            codegen::kit::fetch(url, std::path::Path::new(path), size)
                .map_err(|e| super::failed(Status::InvalidArgument, &e))
        })())
    })
}

