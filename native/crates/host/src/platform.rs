//! The clock and payload digest the executable host needs for itself.
//!
//! Nupp's runtime reads the monotonic clock through its own FFI provider, from
//! the same platform source as here, so a worker deadline Lua computes means
//! the same instant when this host checks it.

#[cfg(any(target_vendor = "apple", target_os = "windows"))]
use std::sync::OnceLock;

const P1: u64 = 0x9E37_79B1_85EB_CA87;
const P2: u64 = 0xC2B2_AE3D_27D4_EB4F;
const P3: u64 = 0x1656_67B1_9E37_79F9;
const P4: u64 = 0x85EB_CA77_C2B2_AE63;
const P5: u64 = 0x27D4_EB2F_1656_67C5;

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

/// XXH64 of the payload under seed zero, as the trailer stores it.
pub(crate) fn trailer_digest(bytes: &[u8]) -> [u8; 8] {
    xxh64(bytes, 0).to_le_bytes()
}

fn xxh64(bytes: &[u8], seed: u64) -> u64 {
    let mut at = 0;
    let mut hash = if bytes.len() >= 32 {
        let mut v1 = seed.wrapping_add(P1).wrapping_add(P2);
        let mut v2 = seed.wrapping_add(P2);
        let mut v3 = seed;
        let mut v4 = seed.wrapping_sub(P1);
        while at <= bytes.len() - 32 {
            v1 = round(v1, read64(&bytes[at..]));
            v2 = round(v2, read64(&bytes[at + 8..]));
            v3 = round(v3, read64(&bytes[at + 16..]));
            v4 = round(v4, read64(&bytes[at + 24..]));
            at += 32;
        }
        let mut value = v1
            .rotate_left(1)
            .wrapping_add(v2.rotate_left(7))
            .wrapping_add(v3.rotate_left(12))
            .wrapping_add(v4.rotate_left(18));
        value = merge(value, v1);
        value = merge(value, v2);
        value = merge(value, v3);
        merge(value, v4)
    } else {
        seed.wrapping_add(P5)
    };
    hash = hash.wrapping_add(bytes.len() as u64);
    while at + 8 <= bytes.len() {
        hash ^= round(0, read64(&bytes[at..]));
        hash = hash.rotate_left(27).wrapping_mul(P1).wrapping_add(P4);
        at += 8;
    }
    if at + 4 <= bytes.len() {
        hash ^= u64::from(read32(&bytes[at..])).wrapping_mul(P1);
        hash = hash.rotate_left(23).wrapping_mul(P2).wrapping_add(P3);
        at += 4;
    }
    while at < bytes.len() {
        hash ^= u64::from(bytes[at]).wrapping_mul(P5);
        hash = hash.rotate_left(11).wrapping_mul(P1);
        at += 1;
    }
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(P2);
    hash ^= hash >> 29;
    hash = hash.wrapping_mul(P3);
    hash ^ (hash >> 32)
}

fn round(lane: u64, input: u64) -> u64 {
    lane.wrapping_add(input.wrapping_mul(P2))
        .rotate_left(31)
        .wrapping_mul(P1)
}

fn merge(hash: u64, lane: u64) -> u64 {
    (hash ^ round(0, lane)).wrapping_mul(P1).wrapping_add(P4)
}

fn read64(bytes: &[u8]) -> u64 {
    u64::from_le_bytes(bytes[..8].try_into().expect("eight-byte slice"))
}

fn read32(bytes: &[u8]) -> u32 {
    u32::from_le_bytes(bytes[..4].try_into().expect("four-byte slice"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xxh64_matches_published_vectors() {
        assert_eq!(xxh64(b"", 0), 0xef46_db37_51d8_e999);
        assert_eq!(xxh64(b"abc", 0), 0x44bc_2cf5_ad77_0999);
        assert_eq!(trailer_digest(b""), 0xef46_db37_51d8_e999_u64.to_le_bytes());
    }

    #[test]
    fn the_monotonic_clock_does_not_go_backwards() {
        let before = monotonic_ns();
        std::thread::sleep(std::time::Duration::from_millis(1));
        assert!(monotonic_ns() >= before);
    }
}
