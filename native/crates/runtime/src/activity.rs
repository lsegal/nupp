//! The process-wide readiness generation.
//!
//! Every native family advances this one counter when something a caller could
//! be waiting for changes: a socket turns readable, a file transfer settles, an
//! HTTP transfer produces an event, a child exits or a pipe moves, GPU work
//! finishes. A caller waiting on any mix of them sleeps on the counter once,
//! rather than on one family's condition at a time.
//!
//! The protocol has no lost wakeup when a caller reads [`generation`] *before*
//! it checks the resources it cares about, and then waits from that value: an
//! edge after the read has advanced the counter, so [`wait_since`] returns at
//! once. A wake says only that something changed, so every wait is followed by
//! a recheck.
//!
//! A caller that has to sleep on operating-system handles of its own as well --
//! the Nupp process provider, waiting on a child and its pipes -- cannot wait on
//! the condition variable at the same time. It opens a [`Wake`] instead: a
//! waitable handle every [`advance`] signals, which it adds to its own
//! `WaitForMultipleObjects` or `poll` set. It resets the handle, reads the
//! generation, checks, and then waits, so the same ordering loses no edge.

use std::sync::{Condvar, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

struct Activity {
    generation: Mutex<u64>,
    changed: Condvar,
}

fn activity() -> &'static Activity {
    static ACTIVITY: OnceLock<Activity> = OnceLock::new();
    ACTIVITY.get_or_init(|| Activity {
        generation: Mutex::new(0),
        changed: Condvar::new(),
    })
}

/// The counter's lock. Nothing that can panic runs under it, so a poisoned
/// lock says nothing about the value it holds.
fn locked() -> MutexGuard<'static, u64> {
    activity()
        .generation
        .lock()
        .unwrap_or_else(|error| error.into_inner())
}

/// The current generation.
pub fn generation() -> u64 {
    *locked()
}

/// Records that something changed, and wakes every waiter.
pub fn advance() {
    let mut generation = locked();
    *generation = generation.wrapping_add(1);
    activity().changed.notify_all();
    drop(generation);
    wake::signal();
}

/// Waits until the generation moves past `seen`, or until `timeout` elapses,
/// and answers the generation it found. A zero timeout never sleeps.
pub fn wait_since(seen: u64, timeout: Duration) -> u64 {
    let generation = locked();
    let generation = if *generation == seen && !timeout.is_zero() {
        activity()
            .changed
            .wait_timeout_while(generation, timeout, |current| *current == seen)
            .unwrap_or_else(|error| error.into_inner())
            .0
    } else {
        generation
    };
    *generation
}

/// Opens a waitable handle every [`advance`] signals, and answers its raw value:
/// a manual-reset event `HANDLE` on Windows, and on POSIX the nonblocking read
/// end of a pipe that receives a byte. The opener resets it -- `ResetEvent`, or
/// reading the pipe dry -- before it reads the generation.
pub fn open_wake() -> std::io::Result<u64> {
    wake::open()
}

/// Stops signalling a handle [`open_wake`] answered, and closes it. Answers
/// false for a handle that is not open.
pub fn close_wake(handle: u64) -> bool {
    wake::close(handle)
}

mod wake {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Mutex, MutexGuard};

    /// How many handles are open, so an advance with none takes no second lock.
    static OPEN: AtomicUsize = AtomicUsize::new(0);
    static HANDLES: Mutex<Vec<Handle>> = Mutex::new(Vec::new());

    fn handles() -> MutexGuard<'static, Vec<Handle>> {
        HANDLES.lock().unwrap_or_else(|error| error.into_inner())
    }

    pub fn open() -> std::io::Result<u64> {
        let handle = Handle::create()?;
        let raw = handle.raw();
        let mut open = handles();
        open.push(handle);
        OPEN.store(open.len(), Ordering::Release);
        Ok(raw)
    }

    pub fn close(raw: u64) -> bool {
        let mut open = handles();
        let Some(index) = open.iter().position(|handle| handle.raw() == raw) else {
            return false;
        };
        let handle = open.swap_remove(index);
        OPEN.store(open.len(), Ordering::Release);
        drop(open);
        handle.destroy();
        true
    }

    /// Signals every open handle. Holding the list keeps a close from
    /// destroying a handle this is signalling.
    pub fn signal() {
        if OPEN.load(Ordering::Acquire) == 0 {
            return;
        }
        for handle in handles().iter() {
            handle.signal();
        }
    }

    #[cfg(windows)]
    struct Handle(isize);

    #[cfg(windows)]
    impl Handle {
        fn create() -> std::io::Result<Self> {
            use windows_sys::Win32::System::Threading::CreateEventW;
            // SAFETY: a nameless manual-reset event with default security.
            let event = unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) };
            if event.is_null() {
                return Err(std::io::Error::last_os_error());
            }
            Ok(Self(event as isize))
        }

        fn raw(&self) -> u64 {
            self.0 as u64
        }

        fn signal(&self) {
            // SAFETY: the event stays open while it is in the list.
            unsafe { windows_sys::Win32::System::Threading::SetEvent(self.0 as _) };
        }

        fn destroy(self) {
            // SAFETY: the event was removed from the list, so nothing signals it.
            unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0 as _) };
        }
    }

    #[cfg(unix)]
    struct Handle {
        read: libc::c_int,
        write: libc::c_int,
    }

    #[cfg(unix)]
    impl Handle {
        fn create() -> std::io::Result<Self> {
            let mut ends = [0 as libc::c_int; 2];
            // SAFETY: `ends` has room for the two descriptors pipe writes.
            if unsafe { libc::pipe(ends.as_mut_ptr()) } != 0 {
                return Err(std::io::Error::last_os_error());
            }
            let handle = Self {
                read: ends[0],
                write: ends[1],
            };
            for end in ends {
                // SAFETY: fcntl operates only on the descriptors just created.
                let ok = unsafe {
                    let flags = libc::fcntl(end, libc::F_GETFL);
                    flags >= 0
                        && libc::fcntl(end, libc::F_SETFL, flags | libc::O_NONBLOCK) == 0
                        && libc::fcntl(end, libc::F_SETFD, libc::FD_CLOEXEC) == 0
                };
                if !ok {
                    let error = std::io::Error::last_os_error();
                    handle.destroy();
                    return Err(error);
                }
            }
            Ok(handle)
        }

        fn raw(&self) -> u64 {
            self.read as u64
        }

        fn signal(&self) {
            // A full pipe is already signalled, so a refused byte loses nothing.
            // SAFETY: the descriptor stays open while it is in the list.
            unsafe { libc::write(self.write, [1_u8].as_ptr().cast(), 1) };
        }

        fn destroy(self) {
            // SAFETY: both descriptors belong to this handle alone.
            unsafe {
                libc::close(self.read);
                libc::close(self.write);
            }
        }
    }

    #[cfg(not(any(unix, windows)))]
    struct Handle;

    #[cfg(not(any(unix, windows)))]
    impl Handle {
        fn create() -> std::io::Result<Self> {
            Err(std::io::ErrorKind::Unsupported.into())
        }

        fn raw(&self) -> u64 {
            0
        }

        fn signal(&self) {}

        fn destroy(self) {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn a_wait_from_a_stale_generation_returns_at_once() {
        let seen = generation();
        advance();
        let started = Instant::now();
        assert_ne!(wait_since(seen, Duration::from_secs(5)), seen);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn an_advance_on_another_thread_wakes_a_waiter() {
        let seen = generation();
        let waker = std::thread::spawn(|| {
            std::thread::sleep(Duration::from_millis(20));
            advance();
        });
        let started = Instant::now();
        assert_ne!(wait_since(seen, Duration::from_secs(5)), seen);
        assert!(started.elapsed() < Duration::from_secs(5));
        waker.join().unwrap();
    }

    #[test]
    fn an_advance_signals_every_open_wake_handle() {
        let first = open_wake().unwrap();
        let second = open_wake().unwrap();
        advance();
        assert!(signalled(first) && signalled(second));
        assert!(close_wake(first));
        assert!(!close_wake(first), "a closed handle is not open");
        advance();
        assert!(signalled(second));
        assert!(close_wake(second));
    }

    /// Whether a wake handle was signalled, resetting it as its opener would.
    #[cfg(windows)]
    fn signalled(handle: u64) -> bool {
        use windows_sys::Win32::System::Threading::{ResetEvent, WaitForSingleObject};
        // SAFETY: the handle is an open event this test owns.
        unsafe {
            let set = WaitForSingleObject(handle as _, 0) == 0;
            ResetEvent(handle as _);
            set
        }
    }

    #[cfg(unix)]
    fn signalled(handle: u64) -> bool {
        let mut scratch = [0_u8; 64];
        let mut set = false;
        // SAFETY: the descriptor is an open nonblocking pipe this test owns.
        while unsafe { libc::read(handle as _, scratch.as_mut_ptr().cast(), scratch.len()) } > 0 {
            set = true;
        }
        set
    }

    #[test]
    fn a_zero_timeout_never_sleeps() {
        let started = Instant::now();
        wait_since(generation(), Duration::ZERO);
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
