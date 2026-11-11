#!/bin/sh
# Record public native-runtime and artifact-size measurements without
# turning hosted-runner timing into a pass/fail threshold.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
results=${1:?usage: measure-native-runtime.sh OUTPUT_DIRECTORY}
case "$results" in
   /*) ;;
   *) results=$root/$results ;;
esac
mkdir -p "$results"

file_bytes() {
   wc -c < "$1" | tr -d ' '
}

cd "$root"
{
   printf 'commit=%s\n' "${GITHUB_SHA:-$(git rev-parse HEAD)}"
   printf 'runner=%s/%s\n' "${RUNNER_OS:-$(uname -s)}" "${RUNNER_ARCH:-$(uname -m)}"
   printf 'node='
   node --version
} > "$results/metadata.txt"

# The benchmark target stages public dependencies from the compiler build.
# A clean measurement runner has no ambient root build to inherit.
./bin/nupp build
bench/native-runtime/run.sh > "$results/public-boundary.txt"
bench/native-runtime/resource.sh > "$results/resources.txt"


benchmark=bench/native-runtime/build/native-runtime-benchmark
if [ -f "$benchmark.exe" ]; then
   benchmark=$benchmark.exe
fi
[ -f "$benchmark" ]
benchmark_provider=bench/native-runtime/build/lib/nupp_native
if [ ! -f "$benchmark_provider" ]; then
   benchmark_provider=$(find bench/native-runtime/build/lib -maxdepth 1 -type f \
      \( -name 'nupp_native.dll' -o -name 'libnupp_native.so' \
         -o -name 'libnupp_native.dylib' \) -print | head -n 1)
fi
[ -n "$benchmark_provider" ]

{
   printf 'benchmark_binary_bytes=%s\n' "$(file_bytes "$benchmark")"
   printf 'benchmark_provider_bytes=%s\n' "$(file_bytes "$benchmark_provider")"
} > "$results/artifact-size.txt"

printf 'native runtime measurements written to %s\n' "$results"
