/* The versioned Rust-native provider ABI, an internal boundary between the
 * compiler's runtime and the provider built from the same checkout. The pinned
 * stage-zero compiler also loads it and requires this version exactly, so the
 * ABI grows only by addition: see "Provider ABI evolution" in
 * docs/reference/native-runtime.md. A call that returns an int32_t status
 * returns NUPP_NATIVE_INTERNAL for a panic inside it rather than aborting. */

#ifndef NUPP_NATIVE_H
#define NUPP_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#   if defined(NUPP_NATIVE_STATIC)
#       define NUPP_NATIVE_EXPORT
#   elif defined(NUPP_NATIVE_BUILD)
#       define NUPP_NATIVE_EXPORT __declspec(dllexport)
#   else
#       define NUPP_NATIVE_EXPORT __declspec(dllimport)
#   endif
#else
#   define NUPP_NATIVE_EXPORT __attribute__((visibility("default")))
#endif

#define NUPP_NATIVE_ABI_VERSION 2u

#define NUPP_NATIVE_OK 0
#define NUPP_NATIVE_INVALID_ARGUMENT 1
/* A handle table or a provider resource limit is exhausted. */
#define NUPP_NATIVE_CAPACITY 2
#define NUPP_NATIVE_STALE_HANDLE 3
#define NUPP_NATIVE_CLOSED 4
#define NUPP_NATIVE_INTERNAL 5
/* An output buffer is too small, and the call's length output holds the byte
 * count it needs. nuppNativeBytesCopy still returns CAPACITY here, because the
 * pinned stage-zero compiler reads that code as its size-probe answer. */
#define NUPP_NATIVE_BUFFER_TOO_SMALL 6
/* A value does not fit the range its ABI type, or Nupp's exact integers, can
 * carry. */
#define NUPP_NATIVE_OUT_OF_RANGE 7
/* The facility is absent from this machine. */
#define NUPP_NATIVE_UNAVAILABLE 8

/* A call that copies bytes into caller-owned storage writes the byte count to
 * its length output first, then returns BUFFER_TOO_SMALL when the capacity is
 * short. A zero-capacity call therefore asks the size of a nonempty value, and
 * no copied output carries a trailing NUL. */

#define NUPP_NATIVE_FEATURE_BASE (UINT64_C(1) << 0)
/* Bit 1 was UUIDs, bit 2 the GPU provider, bit 4 HTTP, bits 5 to 7 processes,
 * files and the file-transfer lane, bits 8 and 9 the network and TLS families
 * and bit 13 their endpoint calls. Nupp provides all of them now. */
#define NUPP_NATIVE_FEATURE_URI (UINT64_C(1) << 3)
/* The code generator. Its exports belong to the compiler, which declares
 * them itself; this header does not. */
#define NUPP_NATIVE_FEATURE_CODEGEN (UINT64_C(1) << 11)
#define NUPP_NATIVE_FEATURE_AOT_RUNTIME (UINT64_C(1) << 12)
/* The process-wide readiness generation, nuppNativePoll and nuppNativeWait. */
#define NUPP_NATIVE_FEATURE_READINESS (UINT64_C(1) << 14)

#ifdef __cplusplus
extern "C" {
#endif

/* A borrowed byte range, read only for the call that takes it. Each family
 * once declared its own identical struct; those names remain as aliases of
 * this one, and new calls take NuppNativeSlice. */
typedef struct {
    const uint8_t *data;
    size_t length;
} NuppNativeSlice;

NUPP_NATIVE_EXPORT uint32_t nuppNativeAbiVersion(void);
NUPP_NATIVE_EXPORT uint64_t nuppNativeFeatures(void);
/* The message of the last call on this thread that failed. A call that
 * succeeds leaves it as it was, so read it only after a failure. */
NUPP_NATIVE_EXPORT const char *nuppNativeLastError(void);

/* Present when NUPP_NATIVE_FEATURE_AOT_RUNTIME is set: the table an
 * ahead-of-time compiled Lua module's registrar is handed. Null when the
 * runtime cannot find the Lua API in this process. */
NUPP_NATIVE_EXPORT const void *nuppAotRuntime(void);

NUPP_NATIVE_EXPORT int32_t nuppNativeBytesCopy(
    uint64_t handle, uint8_t *data, size_t capacity, size_t *length);
NUPP_NATIVE_EXPORT int32_t nuppNativeBytesRelease(uint64_t handle);

NUPP_NATIVE_EXPORT size_t nuppNativeAvailableParallelism(void);

/* Test-only: defined only by a provider built with its panic-probe feature,
 * which no release selects. It panics inside the export boundary, so it
 * returns NUPP_NATIVE_INTERNAL with the panic as the last error. */
NUPP_NATIVE_EXPORT int32_t nuppNativePanicProbe(void);

/* Present when NUPP_NATIVE_FEATURE_READINESS is set. One process-wide
 * generation that every family advances when something a caller could be
 * waiting for changes. A caller waiting on any mix of them sleeps here once;
 * the families Nupp provides through the FFI sleep on their own handles and
 * the wake handle below instead.
 *
 * Poll the generation first, then check the resources you are waiting for
 * with their non-blocking calls, and wait from the generation you polled:
 * any change after the poll returns the wait at once, so no edge is lost. A
 * wake says only that something changed; check again after every wait. */
NUPP_NATIVE_EXPORT int32_t nuppNativePoll(uint64_t *generation);
NUPP_NATIVE_EXPORT int32_t nuppNativeWait(
    uint64_t generation, uint64_t timeout_ms, uint64_t *output_generation);

/* Present when NUPP_NATIVE_FEATURE_READINESS is set, for a caller that has to
 * sleep on handles of its own as well as the generation. Open answers a
 * waitable handle every advance of the generation signals: a manual-reset
 * event HANDLE on Windows, and on POSIX the nonblocking read end of a pipe
 * that receives a byte. Reset it (ResetEvent, or read the pipe dry), poll the
 * generation, check, and then wait on it with the other handles. Close stops
 * signalling the handle and closes it. */
NUPP_NATIVE_EXPORT int32_t nuppNativeWakeOpen(uint64_t *handle);
NUPP_NATIVE_EXPORT int32_t nuppNativeWakeClose(uint64_t handle);

/* Present when NUPP_NATIVE_FEATURE_URI is set. URI values are immutable
 * generational handles. Text and components are copied into caller-owned
 * storage. */
#define NUPP_NATIVE_URI_TEXT 0u
#define NUPP_NATIVE_URI_SCHEME 1u
#define NUPP_NATIVE_URI_AUTHORITY 2u
#define NUPP_NATIVE_URI_USERNAME 3u
#define NUPP_NATIVE_URI_PASSWORD 4u
#define NUPP_NATIVE_URI_HOST 5u
#define NUPP_NATIVE_URI_PATH 6u
#define NUPP_NATIVE_URI_QUERY 7u
#define NUPP_NATIVE_URI_FRAGMENT 8u
NUPP_NATIVE_EXPORT int32_t nuppNativeUriParse(
    const uint8_t *data, size_t length, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeUriRelease(uint64_t uri);
NUPP_NATIVE_EXPORT int32_t nuppNativeUriPart(
    uint64_t uri, uint32_t kind, uint8_t *output, size_t capacity,
    size_t *length, int32_t *present);
NUPP_NATIVE_EXPORT int32_t nuppNativeUriPort(
    uint64_t uri, int32_t *port);

#ifdef __cplusplus
}
#endif

#endif /* NUPP_NATIVE_H */
