/* setenv and unsetenv are POSIX, which -std=c11 hides from glibc's headers. */
#define _POSIX_C_SOURCE 200112L

#include "nupp_native.h"

#include <stdio.h>
#include <stdlib.h>

/* These records are read and written directly across the C/Rust boundary.
 * Keep the offsets explicit so every platform's smoke build checks the layout
 * LuaJIT's FFI and the Rust repr(C) facade agree on. */
_Static_assert(offsetof(NuppNativeSlice, data) == 0
        && offsetof(NuppNativeSlice, length) == sizeof(void *)
        && sizeof(NuppNativeSlice) == 2 * sizeof(void *),
    "the byte slice has an unexpected layout");
_Static_assert(offsetof(NuppNativeHttpSlice, data) == 0,
    "HTTP slice data moved");
_Static_assert(offsetof(NuppNativeHttpSlice, length) == sizeof(void *),
    "HTTP slice length has an unexpected offset");
_Static_assert(offsetof(NuppNativeHttpHead, state) == 0,
    "HTTP head state moved");
_Static_assert(offsetof(NuppNativeHttpHead, status) == 4,
    "HTTP head status has an unexpected offset");
_Static_assert(offsetof(NuppNativeHttpHead, version) == 6,
    "HTTP head version has an unexpected offset");
_Static_assert(offsetof(NuppNativeHttpHead, url_length) == 8,
    "HTTP head URL length has an unexpected offset");
_Static_assert(offsetof(NuppNativeHttpHead, headers_length)
        == 8 + sizeof(size_t),
    "HTTP head header length has an unexpected offset");
_Static_assert(offsetof(NuppNativeHttpReady, transfer) == 0,
    "HTTP ready handle moved");
_Static_assert(offsetof(NuppNativeHttpReady, tokens) == sizeof(uint64_t),
    "HTTP ready tokens have an unexpected offset");
_Static_assert(offsetof(NuppNativeTlsOptions, certificate)
        == sizeof(NuppNativeNetSlice),
    "TLS certificate slice has an unexpected offset");
_Static_assert(offsetof(NuppNativeTlsOptions, authority_present)
        == 5 * sizeof(NuppNativeNetSlice),
    "TLS authority-present flag has an unexpected offset");
_Static_assert(offsetof(NuppNativeTlsOptions, verify)
        == 5 * sizeof(NuppNativeNetSlice) + 2 * sizeof(int32_t),
    "TLS verify flag has an unexpected offset");

static int failed(const char *operation, int32_t status) {
    fprintf(stderr, "%s: status %d: %s\n", operation, status,
        nuppNativeLastError());
    return 1;
}

/* The readiness pair rejects a NULL output, and a wait that nothing wakes
 * answers at its timeout with the generation it was given. The network smoke
 * covers a wait that a socket wakes. */
static int readiness_generation_answers_waiters(void) {
    uint64_t generation = 0, found = 0;
    int32_t status;
    if (nuppNativePoll(NULL) != NUPP_NATIVE_INVALID_ARGUMENT
        || nuppNativeWait(0, 0, NULL) != NUPP_NATIVE_INVALID_ARGUMENT) {
        fprintf(stderr, "a readiness output of NULL was accepted\n");
        return 1;
    }
    if (!(nuppNativeFeatures() & NUPP_NATIVE_FEATURE_READINESS)) {
        fprintf(stderr, "the readiness feature bit is absent\n");
        return 1;
    }
    status = nuppNativePoll(&generation);
    if (status != NUPP_NATIVE_OK) return failed("readiness poll", status);
    status = nuppNativeWait(generation, 10, &found);
    if (status != NUPP_NATIVE_OK) return failed("readiness wait", status);
    if (found != generation) {
        fprintf(stderr, "an idle readiness wait moved the generation\n");
        return 1;
    }
    return 0;
}

int main(void) {
    size_t length = 0;
    uint64_t uri = 0;
    uint64_t client = 0;
    NuppNativeHttpClientOptions http_options = {0};
    int32_t status;

    if (nuppNativeAbiVersion() != NUPP_NATIVE_ABI_VERSION) {
        fprintf(stderr, "unexpected ABI version\n");
        return 1;
    }
    if ((nuppNativeFeatures() & (NUPP_NATIVE_FEATURE_BASE
            | NUPP_NATIVE_FEATURE_URI | NUPP_NATIVE_FEATURE_HTTP
            | NUPP_NATIVE_FEATURE_NET | NUPP_NATIVE_FEATURE_TLS))
        != (NUPP_NATIVE_FEATURE_BASE
            | NUPP_NATIVE_FEATURE_URI | NUPP_NATIVE_FEATURE_HTTP
            | NUPP_NATIVE_FEATURE_NET | NUPP_NATIVE_FEATURE_TLS)) {
        fprintf(stderr, "a requested Rust-native feature bit is absent\n");
        return 1;
    }
    {
        int32_t connected = 0;
        if (nuppNativeTlsConnected(0, &connected)
                != NUPP_NATIVE_STALE_HANDLE
            || nuppNativeTlsConnected(0, NULL)
                != NUPP_NATIVE_INVALID_ARGUMENT) {
            fprintf(stderr, "invalid TLS handle or output was accepted\n");
            return 1;
        }
    }
    if (readiness_generation_answers_waiters()) return 1;
    status = nuppNativeUriParse((const uint8_t *)"https://EXAMPLE.com",
        sizeof "https://EXAMPLE.com" - 1, &uri);
    if (status != NUPP_NATIVE_OK) return failed("URI parse", status);
    {
        uint8_t small[2];
        size_t part_length = 0;
        int32_t present = 0;
        if (nuppNativeUriPart(uri, NUPP_NATIVE_URI_HOST, NULL, 0,
                &part_length, &present)
                != NUPP_NATIVE_BUFFER_TOO_SMALL
            || part_length != sizeof "example.com" - 1) {
            fprintf(stderr, "a URI part size query was not too small\n");
            return 1;
        }
        /* The host is longer than the output. */
        if (nuppNativeUriPart(uri, NUPP_NATIVE_URI_HOST, small, sizeof small,
                &part_length, &present) != NUPP_NATIVE_BUFFER_TOO_SMALL
            || part_length != sizeof "example.com" - 1 || !present) {
            fprintf(stderr, "a short URI part output was not too small\n");
            return 1;
        }
    }
    status = nuppNativeUriRelease(uri);
    if (status != NUPP_NATIVE_OK) return failed("URI release", status);
    if (nuppNativeUriRelease(uri) != NUPP_NATIVE_STALE_HANDLE) {
        fprintf(stderr, "released URI handle was revived\n");
        return 1;
    }
    http_options.connect_timeout_ms = 1000;
    http_options.max_pending_requests = 1;
    http_options.max_connections = 1;
    http_options.max_connections_per_host = 1;
    http_options.proxy_mode = NUPP_NATIVE_HTTP_PROXY_NONE;
    status = nuppNativeHttpClientCreate(&http_options, &client);
    if (status != NUPP_NATIVE_OK) return failed("HTTP client create", status);
    status = nuppNativeHttpClientRelease(client);
    if (status != NUPP_NATIVE_OK) return failed("HTTP client release", status);
    if (nuppNativeHttpClientPending(client, &length)
        != NUPP_NATIVE_STALE_HANDLE) {
        fprintf(stderr, "released HTTP client handle was revived\n");
        return 1;
    }
    return 0;
}
