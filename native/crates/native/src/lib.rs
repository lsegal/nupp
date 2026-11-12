//! Versioned Rust-native facade. No legacy provider symbol is defined here.

#![forbid(unsafe_op_in_unsafe_fn)]

mod abi;

use abi::{ABI_VERSION, Arena, Handle, Status, boundary, guard, last_error_ptr, set_last_error};
use std::ffi::c_char;
use std::ptr;
use std::sync::{Mutex, OnceLock};

#[cfg(feature = "uri")]
mod uri;

/// What `nuppNativeLastError` answers if reading the last error panics.
static PANICKED: &std::ffi::CStr = c"native provider panicked";

const FEATURE_BASE: u64 = 1 << 0;
// Bit 1 was UUIDs, bit 2 the GPU provider, bit 4 HTTP, bits 5 to 7 processes,
// files and the file-transfer lane, bits 8 and 9 the network and TLS families
// and bit 13 their endpoint calls. Nupp provides all of them now, and bit 11,
// the code generator, is a library of its own. The bits stay unassigned, so an
// old caller asking for one reads its absence.
const FEATURE_URI: u64 = 1 << 3;
const FEATURE_AOT_RUNTIME: u64 = 1 << 12;
const FEATURE_READINESS: u64 = 1 << 14;

fn bytes() -> &'static Mutex<Arena<Box<[u8]>>> {
    static BYTES: OnceLock<Mutex<Arena<Box<[u8]>>>> = OnceLock::new();
    BYTES.get_or_init(|| Mutex::new(Arena::new()))
}

/// Keeps provider-produced bytes behind a handle the caller copies out of.
#[cfg(test)]
pub(crate) fn store_bytes(value: Vec<u8>) -> Result<u64, i32> {
    match bytes().lock() {
        Ok(mut arena) => arena
            .insert(value.into_boxed_slice())
            .map(Handle::raw)
            .map_err(|status| failed(status, "byte handle capacity is exhausted")),
        Err(_) => Err(failed(Status::Internal, "byte handle store is poisoned")),
    }
}

pub(crate) fn failed(status: Status, message: &str) -> i32 {
    set_last_error(message);
    status.code()
}

#[cfg(feature = "uri")]
pub(crate) fn input<'a>(data: *const u8, length: usize) -> Result<&'a [u8], i32> {
    if length == 0 {
        return Ok(&[]);
    }
    if data.is_null() {
        return Err(failed(Status::InvalidArgument, "input pointer is null"));
    }
    // SAFETY: the versioned ABI requires `data` to remain readable for
    // `length` bytes for the duration of this call.
    Ok(unsafe { std::slice::from_raw_parts(data, length) })
}

#[unsafe(no_mangle)]
pub extern "C" fn nuppNativeAbiVersion() -> u32 {
    guard(0, || ABI_VERSION)
}

#[unsafe(no_mangle)]
pub extern "C" fn nuppNativeFeatures() -> u64 {
    guard(0, || {
        FEATURE_BASE
            | FEATURE_READINESS
            | if cfg!(feature = "uri") {
                FEATURE_URI
            } else {
                0
            }
            | if cfg!(nupp_aot_runtime) {
                FEATURE_AOT_RUNTIME
            } else {
                0
            }
    })
}

#[cfg(nupp_aot_runtime)]
unsafe extern "C" {
    static ks_rt_table: [*const std::ffi::c_void; 1];
    fn ks_rt_bind() -> std::ffi::c_int;
}

/// The AOT runtime's table (`native/aotruntime`, which `build.rs` links): what
/// an LLVM-compiled Lua-builder module's registrar is handed, and calls the
/// runtime through. Null when the runtime cannot find the Lua API in this
/// process (Windows binds it here).
#[cfg(nupp_aot_runtime)]
#[unsafe(no_mangle)]
pub extern "C" fn nuppAotRuntime() -> *const std::ffi::c_void {
    guard(std::ptr::null(), || {
        // SAFETY: binding only reads the loaded modules' export tables.
        if unsafe { ks_rt_bind() } == 0 {
            return std::ptr::null();
        }
        std::ptr::addr_of!(ks_rt_table).cast()
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nuppNativeLastError() -> *const c_char {
    guard(PANICKED.as_ptr(), || last_error_ptr())
}

#[unsafe(no_mangle)]
/// Copies the allocation behind a byte handle into caller-owned storage.
///
/// # Safety
///
/// `output_length` must be writable. When `capacity` is nonzero, `output_data`
/// must be writable for `capacity` bytes.
pub unsafe extern "C" fn nuppNativeBytesCopy(
    raw: u64,
    output_data: *mut u8,
    capacity: usize,
    output_length: *mut usize,
) -> i32 {
    boundary(|| {
        if output_length.is_null() || (capacity != 0 && output_data.is_null()) {
            return failed(Status::InvalidArgument, "byte copy output is null");
        }
        let arena = match bytes().lock() {
            Ok(arena) => arena,
            Err(_) => return failed(Status::Internal, "byte handle store is poisoned"),
        };
        let value = match arena.get(Handle::from_raw(raw)) {
            Ok(value) => value,
            Err(status) => return failed(status, "byte handle is stale"),
        };
        // SAFETY: `output_length` was checked above.
        unsafe { output_length.write(value.len()) };
        // CAPACITY rather than BUFFER_TOO_SMALL: the pinned stage-zero compiler
        // reads this code as the answer to its size probe. It moves once a pinned
        // release accepts both.
        if capacity < value.len() {
            return failed(Status::Capacity, "byte copy output is too small");
        }
        if !value.is_empty() {
            // SAFETY: the caller promised `capacity` writable bytes and the check
            // above proves the allocation fits.
            unsafe { ptr::copy_nonoverlapping(value.as_ptr(), output_data, value.len()) };
        }
        Status::Ok.code()
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nuppNativeBytesRelease(raw: u64) -> i32 {
    boundary(|| match bytes().lock() {
        Ok(mut arena) => match arena.remove(Handle::from_raw(raw)) {
            Ok(_) => Status::Ok.code(),
            Err(status) => failed(status, "byte handle is stale"),
        },
        Err(_) => failed(Status::Internal, "byte handle store is poisoned"),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nuppNativeAvailableParallelism() -> usize {
    guard(1, || {
        std::thread::available_parallelism().map_or(1, usize::from)
    })
}

#[unsafe(no_mangle)]
/// Snapshots the process-wide readiness generation.
///
/// # Safety
///
/// `generation` must be writable.
pub unsafe extern "C" fn nuppNativePoll(generation: *mut u64) -> i32 {
    boundary(|| {
        if generation.is_null() {
            return failed(
                Status::InvalidArgument,
                "readiness generation output is null",
            );
        }
        // SAFETY: the output was checked above.
        unsafe { generation.write(nupp_native_runtime::activity::generation()) };
        Status::Ok.code()
    })
}

#[unsafe(no_mangle)]
/// Sleeps until the process-wide readiness generation moves past
/// `generation`, or `timeout_ms` passes, and writes the generation it found.
///
/// # Safety
///
/// `output_generation` must be writable.
pub unsafe extern "C" fn nuppNativeWait(
    generation: u64,
    timeout_ms: u64,
    output_generation: *mut u64,
) -> i32 {
    boundary(|| {
        if output_generation.is_null() {
            return failed(
                Status::InvalidArgument,
                "readiness generation output is null",
            );
        }
        let found = nupp_native_runtime::activity::wait_since(
            generation,
            std::time::Duration::from_millis(timeout_ms),
        );
        // SAFETY: the output was checked above.
        unsafe { output_generation.write(found) };
        Status::Ok.code()
    })
}

#[unsafe(no_mangle)]
/// Opens a waitable handle every advance of the readiness generation signals,
/// for a caller sleeping on handles of its own as well: a manual-reset event
/// on Windows, the read end of a nonblocking pipe on POSIX.
///
/// # Safety
///
/// `handle` must be writable.
pub unsafe extern "C" fn nuppNativeWakeOpen(handle: *mut u64) -> i32 {
    boundary(|| {
        if handle.is_null() {
            return failed(Status::InvalidArgument, "wake handle output is null");
        }
        match nupp_native_runtime::activity::open_wake() {
            Ok(raw) => {
                // SAFETY: the output was checked above.
                unsafe { handle.write(raw) };
                Status::Ok.code()
            }
            Err(error) => failed(Status::Internal, &error.to_string()),
        }
    })
}

#[unsafe(no_mangle)]
/// Stops signalling and closes a handle `nuppNativeWakeOpen` answered.
pub extern "C" fn nuppNativeWakeClose(handle: u64) -> i32 {
    boundary(|| {
        if nupp_native_runtime::activity::close_wake(handle) {
            Status::Ok.code()
        } else {
            failed(Status::InvalidArgument, "wake handle is not open")
        }
    })
}

#[cfg(feature = "panic-probe")]
#[unsafe(no_mangle)]
/// Panics inside the export boundary, for tests that cross a provider panic
/// from a host. Only a build with the `panic-probe` feature defines it.
pub extern "C" fn nuppNativePanicProbe() -> i32 {
    boundary(|| panic!("the panic probe tripped"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The functions a declaration list names, each the identifier before
    /// the first `(` of a statement that starts with `marker`.
    fn declared(text: &str, marker: &str) -> std::collections::BTreeSet<String> {
        text.split(marker)
            .skip(1)
            .filter_map(|statement| {
                let head = &statement[..statement.find('(')?];
                let name = head
                    .rsplit(|c: char| !(c.is_alphanumeric() || c == '_'))
                    .next()?;
                Some(name.to_owned())
            })
            .collect()
    }

    /// Every export's body runs inside the panic boundary, so a panic beneath
    /// any of them answers a status instead of aborting the process.
    #[test]
    fn every_export_runs_inside_the_panic_boundary() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut unguarded = Vec::new();
        for entry in std::fs::read_dir(root.join("src")).unwrap() {
            let source = std::fs::read_to_string(entry.unwrap().path()).unwrap();
            for statement in source.split("extern \"C\" fn ").skip(1) {
                let Some(name) = statement.split('(').next() else {
                    continue;
                };
                if !name.starts_with("nupp") {
                    continue;
                }
                let body = statement[statement.find('{').unwrap() + 1..].trim_start();
                if !(body.starts_with("boundary(") || body.starts_with("guard(")) {
                    unguarded.push(name.to_owned());
                }
            }
        }
        assert!(
            unguarded.is_empty(),
            "exports outside the boundary: {unguarded:?}"
        );
    }

    #[test]
    fn the_definition_declares_every_export_and_feature_bit() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        // The ABI is defined in Nupp; the C header is generated from it.
        let definition = std::fs::read_to_string(root.join("../../abi/nuppnative.nupp")).unwrap();
        for (name, value) in [
            ("BASE", FEATURE_BASE),
            ("URI", FEATURE_URI),
            ("AOT_RUNTIME", FEATURE_AOT_RUNTIME),
            ("READINESS", FEATURE_READINESS),
        ] {
            let define = format!("\nexport const NUPP_NATIVE_FEATURE_{name} = {value}\n");
            assert!(definition.contains(&define), "the definition lacks {}", define.trim());
        }
        // Everything this crate exports is the definition's.
        let mut exported = std::collections::BTreeSet::new();
        for entry in std::fs::read_dir(root.join("src")).unwrap() {
            let source = std::fs::read_to_string(entry.unwrap().path()).unwrap();
            exported.extend(
                declared(&source, "extern \"C\" fn ")
                    .into_iter()
                    .filter(|name| name.starts_with("nupp")),
            );
        }
        let mut declarations = declared(&definition, "\ncdef function ");
        declarations.retain(|name| name.starts_with("nupp"));
        assert_eq!(exported, declarations);
    }

    #[test]
    fn bytes_are_validated_by_generation() {
        let handle = store_bytes(b"abc".to_vec()).unwrap();
        let mut data = [0; 3];
        let mut length = 0;
        assert_eq!(
            unsafe { nuppNativeBytesCopy(handle, data.as_mut_ptr(), data.len(), &mut length,) },
            0
        );
        assert_eq!(&data[..length], b"abc");
        // The pinned stage zero reads CAPACITY as the answer to its size
        // probe, so this one call keeps it rather than BUFFER_TOO_SMALL.
        assert_eq!(
            unsafe { nuppNativeBytesCopy(handle, data.as_mut_ptr(), 2, &mut length) },
            Status::Capacity.code()
        );
        assert_eq!(length, 3);
        assert_eq!(nuppNativeBytesRelease(handle), 0);
        assert_eq!(nuppNativeBytesRelease(handle), Status::StaleHandle.code());
    }

    #[test]
    fn one_readiness_generation_answers_poll_and_wait() {
        let mut seen = 0;
        assert_eq!(unsafe { nuppNativePoll(&mut seen) }, 0);
        nupp_native_runtime::activity::advance();
        let mut found = seen;
        assert_eq!(unsafe { nuppNativeWait(seen, 5_000, &mut found) }, 0);
        assert_ne!(found, seen);
        assert!(nuppNativeFeatures() & FEATURE_READINESS != 0);
        assert_eq!(
            unsafe { nuppNativePoll(ptr::null_mut()) },
            Status::InvalidArgument.code()
        );
        assert_eq!(
            unsafe { nuppNativeWait(0, 0, ptr::null_mut()) },
            Status::InvalidArgument.code()
        );
    }
}
