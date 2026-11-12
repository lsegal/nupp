//! The export boundary: status codes, the thread's last error, the panic
//! guard every export runs inside, and generation-checked handles. The codes
//! and the version are the definition's (`native/abi/nuppnative.nupp`).

use std::any::Any;
use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char};
use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};

pub(crate) const ABI_VERSION: u32 = 2;

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Status {
    Ok = 0,
    InvalidArgument = 1,
    /// A handle table or a provider resource limit is exhausted.
    Capacity = 2,
    StaleHandle = 3,
    Internal = 5,
    /// An output buffer is too small; the call reports the size it needs.
    BufferTooSmall = 6,
}

impl Status {
    pub(crate) const fn code(self) -> i32 {
        self as i32
    }
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(c"no error".to_owned());
}

pub(crate) fn set_last_error(message: impl fmt::Display) {
    let mut bytes = message.to_string().into_bytes();
    for byte in &mut bytes {
        if *byte == 0 {
            *byte = b'?';
        }
    }
    let value = CString::new(bytes).expect("interior NUL bytes were replaced");
    LAST_ERROR.with(|slot| *slot.borrow_mut() = value);
}

pub(crate) fn with_last_error<T>(read: impl FnOnce(&CStr) -> T) -> T {
    LAST_ERROR.with(|slot| read(slot.borrow().as_c_str()))
}

pub(crate) fn last_error_ptr() -> *const c_char {
    with_last_error(CStr::as_ptr)
}

/// What a panic said, when it said it with text.
fn panic_message(payload: &(dyn Any + Send)) -> &str {
    if let Some(text) = payload.downcast_ref::<&str>() {
        text
    } else if let Some(text) = payload.downcast_ref::<String>() {
        text
    } else {
        "no message"
    }
}

/// Runs one export's body and answers `fallback` if it panics.
///
/// Every native export runs inside this or [`boundary`]. The workspace builds
/// with `panic = "unwind"` so that a panic reaches this catch rather than
/// aborting the process; an unwind that escaped an `extern "C"` function
/// would still abort, which is what keeps it from ever crossing LuaJIT's
/// frames. The panic's text becomes the thread's last error.
pub(crate) fn guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(payload) => {
            set_last_error(format_args!(
                "native provider panicked: {}",
                panic_message(payload.as_ref())
            ));
            // A payload's destructor may itself panic, so it is dropped under a
            // second catch. Only the payload of that second panic, whose own
            // destructor could panic again, is leaked; an ordinary message is
            // freed, which LeakSanitizer reported when every payload was leaked.
            if let Err(nested) = catch_unwind(AssertUnwindSafe(move || drop(payload))) {
                std::mem::forget(nested);
            }
            fallback
        }
    }
}

/// Runs one status-returning export's body, answering INTERNAL if it panics.
pub(crate) fn boundary(body: impl FnOnce() -> i32) -> i32 {
    guard(Status::Internal.code(), body)
}

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct Handle(u64);

impl Handle {
    pub(crate) const fn from_raw(raw: u64) -> Self {
        Self(raw)
    }

    pub(crate) const fn raw(self) -> u64 {
        self.0
    }

    fn new(index: usize, generation: u32) -> Self {
        debug_assert!(index < u32::MAX as usize);
        Self((u64::from(generation) << 32) | (index as u64 + 1))
    }

    fn parts(self) -> Option<(usize, u32)> {
        let index = (self.0 & u64::from(u32::MAX)) as u32;
        let generation = (self.0 >> 32) as u32;
        if index == 0 || generation == 0 {
            None
        } else {
            Some(((index - 1) as usize, generation))
        }
    }
}

struct Slot<T> {
    generation: u32,
    value: Option<T>,
}

/// An arena whose public identities cannot alias a reused slot.
pub(crate) struct Arena<T> {
    slots: Vec<Slot<T>>,
    free: Vec<usize>,
}

impl<T> Arena<T> {
    pub(crate) const fn new() -> Self {
        Self {
            slots: Vec::new(),
            free: Vec::new(),
        }
    }

    pub(crate) fn insert(&mut self, value: T) -> Result<Handle, Status> {
        let index = if let Some(index) = self.free.pop() {
            index
        } else {
            if self.slots.len() == u32::MAX as usize {
                return Err(Status::Capacity);
            }
            self.slots.push(Slot {
                generation: 1,
                value: None,
            });
            self.slots.len() - 1
        };
        let slot = &mut self.slots[index];
        debug_assert!(slot.value.is_none());
        slot.value = Some(value);
        Ok(Handle::new(index, slot.generation))
    }

    pub(crate) fn get(&self, handle: Handle) -> Result<&T, Status> {
        let (index, generation) = handle.parts().ok_or(Status::StaleHandle)?;
        let slot = self.slots.get(index).ok_or(Status::StaleHandle)?;
        if slot.generation != generation {
            return Err(Status::StaleHandle);
        }
        slot.value.as_ref().ok_or(Status::StaleHandle)
    }

    pub(crate) fn remove(&mut self, handle: Handle) -> Result<T, Status> {
        let (index, generation) = handle.parts().ok_or(Status::StaleHandle)?;
        let slot = self.slots.get_mut(index).ok_or(Status::StaleHandle)?;
        if slot.generation != generation {
            return Err(Status::StaleHandle);
        }
        let value = slot.value.take().ok_or(Status::StaleHandle)?;
        if slot.generation != u32::MAX {
            slot.generation += 1;
            self.free.push(index);
        }
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reused_slot_never_revives_the_old_handle() {
        let mut arena = Arena::new();
        let first = arena.insert("first").unwrap();
        assert_eq!(arena.remove(first), Ok("first"));
        let second = arena.insert("second").unwrap();
        assert_ne!(first, second);
        assert_eq!(arena.get(first), Err(Status::StaleHandle));
        assert_eq!(arena.get(second), Ok(&"second"));
    }

    #[test]
    fn zero_and_double_release_are_stale() {
        let mut arena = Arena::new();
        assert_eq!(arena.get(Handle::from_raw(0)), Err(Status::StaleHandle));
        let handle = arena.insert(42).unwrap();
        assert_eq!(arena.remove(handle), Ok(42));
        assert_eq!(arena.remove(handle), Err(Status::StaleHandle));
    }

    #[test]
    fn a_panic_inside_the_boundary_is_an_internal_status() {
        let status = boundary(|| panic!("the provider tripped"));
        assert_eq!(status, Status::Internal.code());
        with_last_error(|value| {
            assert_eq!(
                value.to_bytes(),
                b"native provider panicked: the provider tripped"
            )
        });
        assert_eq!(guard(7, || -> u32 { panic!("{}", 1) }), 7);
        with_last_error(|value| assert_eq!(value.to_bytes(), b"native provider panicked: 1"));
        assert_eq!(
            boundary(|| Status::StaleHandle.code()),
            Status::StaleHandle.code()
        );
    }

    #[test]
    fn a_payload_whose_destructor_panics_still_answers_the_fallback() {
        // Both payloads are zero-sized, so neither allocates and the one the
        // boundary leaks by design is nothing LeakSanitizer can see.
        struct Bomb;
        impl Drop for Bomb {
            fn drop(&mut self) {
                std::panic::panic_any(());
            }
        }
        assert_eq!(guard(9, || -> u32 { std::panic::panic_any(Bomb) }), 9);
        with_last_error(|value| {
            assert_eq!(value.to_bytes(), b"native provider panicked: no message")
        });
    }

    #[test]
    fn error_text_replaces_interior_nuls() {
        set_last_error("bad\0message");
        with_last_error(|value| assert_eq!(value.to_bytes(), b"bad?message"));
    }

    /// The codes and version here are the definition's.
    #[test]
    fn statuses_match_the_definition() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let definition = std::fs::read_to_string(root.join("../../abi/nuppnative.nupp")).unwrap();
        for (name, value) in [
            ("ABI_VERSION", ABI_VERSION as i32),
            ("OK", Status::Ok.code()),
            ("INVALID_ARGUMENT", Status::InvalidArgument.code()),
            ("CAPACITY", Status::Capacity.code()),
            ("STALE_HANDLE", Status::StaleHandle.code()),
            ("INTERNAL", Status::Internal.code()),
            ("BUFFER_TOO_SMALL", Status::BufferTooSmall.code()),
        ] {
            let define = format!("\nexport const NUPP_NATIVE_{name} = {value}\n");
            assert!(definition.contains(&define), "the definition lacks {}", define.trim());
        }
    }
}
