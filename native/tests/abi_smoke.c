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
    uint64_t uri = 0;
    int32_t status;

    if (nuppNativeAbiVersion() != NUPP_NATIVE_ABI_VERSION) {
        fprintf(stderr, "unexpected ABI version\n");
        return 1;
    }
    if ((nuppNativeFeatures()
            & (NUPP_NATIVE_FEATURE_BASE | NUPP_NATIVE_FEATURE_URI))
        != (NUPP_NATIVE_FEATURE_BASE | NUPP_NATIVE_FEATURE_URI)) {
        fprintf(stderr, "a requested Rust-native feature bit is absent\n");
        return 1;
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
    return 0;
}
