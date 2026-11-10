//! The host's monotonic clock.
//!
//! Worker deadlines are computed in Lua from `nupp.runtime.provider.nativeplatform`
//! and checked here, so this reads the same source that module does:
//! `QueryPerformanceCounter` on Windows, `mach_absolute_time` on Darwin and
//! `CLOCK_MONOTONIC` elsewhere.

#[cfg(any(target_vendor = "apple", target_os = "windows"))]
use std::sync::OnceLock;

pub(crate) fn monotonic_ns() -> u64 {
    platform_monotonic_ns()
}

#[cfg(target_vendor = "apple")]
#[repr(C)]
struct MachTimebaseInfo {
    numer: u32,
    denom: u32,
}

#[cfg(target_vendor = "apple")]
unsafe extern "C" {
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut MachTimebaseInfo) -> i32;
}

#[cfg(target_vendor = "apple")]
fn platform_monotonic_ns() -> u64 {
    static TIMEBASE: OnceLock<(u64, u64)> = OnceLock::new();
    let (numer, denom) = *TIMEBASE.get_or_init(|| {
        let mut info = MachTimebaseInfo { numer: 0, denom: 0 };
        // SAFETY: `info` is writable and the Darwin function fills this fixed
        // record without retaining the pointer.
        let status = unsafe { mach_timebase_info(&mut info) };
        assert_eq!(status, 0, "mach_timebase_info failed");
        assert_ne!(
            info.denom, 0,
            "mach_timebase_info returned a zero denominator"
        );
        (u64::from(info.numer), u64::from(info.denom))
    });
    // SAFETY: this has no arguments and returns the kernel's monotonic ticks.
    let ticks = unsafe { mach_absolute_time() };
    (u128::from(ticks) * u128::from(numer) / u128::from(denom)).min(u128::from(u64::MAX)) as u64
}

#[cfg(all(unix, not(target_vendor = "apple")))]
#[repr(C)]
struct Timespec {
    seconds: std::os::raw::c_long,
    nanoseconds: std::os::raw::c_long,
}

#[cfg(all(unix, not(target_vendor = "apple")))]
unsafe extern "C" {
    fn clock_gettime(clock: i32, time: *mut Timespec) -> i32;
}

#[cfg(all(unix, not(target_vendor = "apple")))]
fn platform_monotonic_ns() -> u64 {
    const CLOCK_MONOTONIC: i32 = 1;
    let mut time = Timespec {
        seconds: 0,
        nanoseconds: 0,
    };
    // SAFETY: `time` is writable and clock_gettime does not retain it.
    let status = unsafe { clock_gettime(CLOCK_MONOTONIC, &mut time) };
    assert_eq!(status, 0, "clock_gettime(CLOCK_MONOTONIC) failed");
    let seconds = u64::try_from(time.seconds).expect("monotonic seconds are non-negative");
    let nanoseconds =
        u64::try_from(time.nanoseconds).expect("monotonic nanoseconds are non-negative");
    seconds
        .saturating_mul(1_000_000_000)
        .saturating_add(nanoseconds)
}

#[cfg(target_os = "windows")]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn QueryPerformanceCounter(value: *mut i64) -> i32;
    fn QueryPerformanceFrequency(value: *mut i64) -> i32;
}

#[cfg(target_os = "windows")]
fn platform_monotonic_ns() -> u64 {
    static FREQUENCY: OnceLock<u64> = OnceLock::new();
    let frequency = *FREQUENCY.get_or_init(|| {
        let mut value = 0_i64;
        // SAFETY: `value` is writable and the Windows API does not retain it.
        let status = unsafe { QueryPerformanceFrequency(&mut value) };
        assert_ne!(status, 0, "QueryPerformanceFrequency failed");
        u64::try_from(value).expect("performance-counter frequency is positive")
    });
    let mut value = 0_i64;
    // SAFETY: `value` is writable and the Windows API does not retain it.
    let status = unsafe { QueryPerformanceCounter(&mut value) };
    assert_ne!(status, 0, "QueryPerformanceCounter failed");
    let ticks = u64::try_from(value).expect("performance-counter reading is non-negative");
    (u128::from(ticks) * 1_000_000_000 / u128::from(frequency)).min(u128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_clock_does_not_go_backwards() {
        let first = monotonic_ns();
        std::thread::sleep(std::time::Duration::from_millis(2));
        assert!(monotonic_ns() > first);
    }
}
