#!/bin/sh
# Fails when Rust or C++ comes back into the tree (#8). The compiler, its
# runtime, its host and its providers are all Nupp now, and a checkout builds
# them with no Rust toolchain and no C++ compiler. A `.rs` file, a Cargo
# manifest or a `.cpp` file is the first step back to needing one.
#
# C is not refused: C-interop fixtures and benchmark controls are C on
# purpose. The two C++ benchmark controls are exempt by name, so a third one
# is a decision someone has to write down here rather than an accident.
#
# Checks the files git tracks, or with `--stdin` the paths read from standard
# input, one per line.

set -eu

case "${1:-}" in
    --stdin) list() { cat; } ;;
    '') list() { git -C "$(dirname "$0")/../.." ls-files; } ;;
    *) printf 'usage: %s [--stdin]\n' "$0" >&2; exit 2 ;;
esac

refused=$(list | while IFS= read -r path; do
    case "$path" in
        # Benchmark controls: what a Nupp benchmark is measured against.
        bench/serde-spike/serde_spike.cpp) continue ;;
        bench/simd-json/native/simdjson_control.*) continue ;;
    esac
    case "$path" in
        *.rs|*.cpp|*.cxx|*.cc|*.c++) printf '%s\n' "$path" ;;
        Cargo.toml|*/Cargo.toml|Cargo.lock|*/Cargo.lock) printf '%s\n' "$path" ;;
        build.rs|*/build.rs) printf '%s\n' "$path" ;;
        rust-toolchain|*/rust-toolchain|rust-toolchain.toml|*/rust-toolchain.toml) printf '%s\n' "$path" ;;
        .cargo/*|*/.cargo/*) printf '%s\n' "$path" ;;
    esac
done)

if [ -n "$refused" ]; then
    printf '%s\n' "Rust or C++ is back in the tree. The compiler, runtime, host and providers are Nupp (#8):" >&2
    printf '%s\n' "$refused" | sed 's/^/  /' >&2
    exit 1
fi
printf '%s\n' "no Rust or C++ sources"
