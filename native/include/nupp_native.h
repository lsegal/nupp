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
/* Bit 1 was UUIDs, bit 2 the GPU provider, and bits 5 to 7 processes, files
 * and the file-transfer lane. Nupp provides all of them now. */
#define NUPP_NATIVE_FEATURE_URI (UINT64_C(1) << 3)
#define NUPP_NATIVE_FEATURE_HTTP (UINT64_C(1) << 4)
#define NUPP_NATIVE_FEATURE_NET (UINT64_C(1) << 8)
#define NUPP_NATIVE_FEATURE_TLS (UINT64_C(1) << 9)
/* The code generator. Its exports belong to the compiler, which declares
 * them itself; this header does not. */
#define NUPP_NATIVE_FEATURE_CODEGEN (UINT64_C(1) << 11)
#define NUPP_NATIVE_FEATURE_AOT_RUNTIME (UINT64_C(1) << 12)
/* The endpoint calls of the network family, which carry an IPv6 scope. */
#define NUPP_NATIVE_FEATURE_NET_ENDPOINT (UINT64_C(1) << 13)
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
 * waiting for changes: a socket or TLS session moves, or an HTTP client has
 * events. A caller waiting on any mix of them sleeps here once.
 *
 * Poll the generation first, then check the resources you are waiting for
 * with their non-blocking calls, and wait from the generation you polled:
 * any change after the poll returns the wait at once, so no edge is lost. A
 * wake says only that something changed; check again after every wait. The
 * family poll and wait calls marked superseded below predate this pair. */
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

/* Present when NUPP_NATIVE_FEATURE_NET is set. Rust owns the resolver,
 * sockets and worker tasks. Host names and write bytes are copied during the
 * call; listeners, connects and streams are distinct generational handles. */
typedef NuppNativeSlice NuppNativeNetSlice;

typedef struct {
    NuppNativeNetSlice host;
    uint16_t port;
    uint32_t backlog;
    int32_t reuse_port;
} NuppNativeNetListenOptions;

typedef struct {
    NuppNativeNetSlice host;
    uint16_t port;
    uint64_t timeout_ms;
} NuppNativeNetConnectOptions;

typedef struct {
    NuppNativeNetSlice path;
    uint32_t backlog;
} NuppNativeNetPathListenOptions;

typedef struct {
    NuppNativeNetSlice path;
    uint64_t timeout_ms;
} NuppNativeNetPathConnectOptions;

typedef struct {
    NuppNativeNetSlice host;
    uint16_t port;
    int32_t reuse_port;
} NuppNativeNetDatagramOptions;

/* Superseded by NuppNativeNetEndpoint, which can carry a link-local peer's
 * scope. It and the calls taking it stay while the pinned stage-zero bundle
 * names them. */
typedef struct {
    uint8_t address[16];
    uint16_t port;
    uint8_t family;
} NuppNativeNetAddress;

/* Present when NUPP_NATIVE_FEATURE_NET_ENDPOINT is set. The caller sets `size`
 * to sizeof(NuppNativeNetEndpoint) before any call reads or writes one. A call
 * refuses a size smaller than this first version's with INVALID_ARGUMENT, and
 * reads or writes only the fields it knows, leaving `size` as it was. `family`
 * is one of the NUPP_NATIVE_NET_ADDRESS values; an IPv4 address fills the
 * first four bytes of `address` and carries no scope or flow label. */
typedef struct {
    uint32_t size;
    uint8_t family;
    uint16_t port;
    uint32_t scope_id;
    uint32_t flowinfo;
    uint8_t address[16];
} NuppNativeNetEndpoint;

#define NUPP_NATIVE_NET_ADDRESS_NONE 0u
#define NUPP_NATIVE_NET_ADDRESS_V4 4u
#define NUPP_NATIVE_NET_ADDRESS_V6 6u
#define NUPP_NATIVE_NET_LISTENER_TCP 0u
#define NUPP_NATIVE_NET_LISTENER_PATH 1u
#define NUPP_NATIVE_NET_ACCEPTED 0u
#define NUPP_NATIVE_NET_PENDING 1u
#define NUPP_NATIVE_NET_READ_DATA 0u
#define NUPP_NATIVE_NET_READ_PENDING 1u
#define NUPP_NATIVE_NET_READ_EOF 2u
#define NUPP_NATIVE_NET_WRITE_ACCEPTED 0u
#define NUPP_NATIVE_NET_WRITE_CLOSED 2u
#define NUPP_NATIVE_NET_CONNECT_PENDING 0u
#define NUPP_NATIVE_NET_CONNECT_READY 1u
#define NUPP_NATIVE_NET_CONNECT_FAILED 2u
#define NUPP_NATIVE_NET_DATAGRAM_MESSAGE 0u
#define NUPP_NATIVE_NET_DATAGRAM_PENDING 1u
#define NUPP_NATIVE_NET_DATAGRAM_SENT 0u
#define NUPP_NATIVE_NET_DATAGRAM_SEND_PENDING 1u
#define NUPP_NATIVE_NET_DATAGRAM_SEND_CLOSED 2u
#define NUPP_NATIVE_NET_STREAM_READ_EOF (UINT32_C(1) << 0)
#define NUPP_NATIVE_NET_STREAM_WRITE_CLOSED (UINT32_C(1) << 1)
#define NUPP_NATIVE_NET_STREAM_CLOSED (UINT32_C(1) << 2)
#define NUPP_NATIVE_NET_STREAM_SHUTTING_DOWN (UINT32_C(1) << 3)
#define NUPP_NATIVE_NET_STREAM_READ_FAILED (UINT32_C(1) << 4)
#define NUPP_NATIVE_NET_STREAM_WRITE_FAILED (UINT32_C(1) << 5)

NUPP_NATIVE_EXPORT int32_t nuppNativeNetListenerCreate(
    const NuppNativeNetListenOptions *options, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetPathListenerCreate(
    const NuppNativeNetPathListenOptions *options, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetListenerPort(
    uint64_t listener, uint16_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetListenerKind(
    uint64_t listener, uint32_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetListenerAccept(
    uint64_t listener, uint32_t *state, uint64_t *stream);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetListenerRelease(
    uint64_t listener);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetConnectCreate(
    const NuppNativeNetConnectOptions *options, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetPathConnectCreate(
    const NuppNativeNetPathConnectOptions *options, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetConnectPoll(
    uint64_t connect, uint32_t *state, uint64_t *stream);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetConnectRelease(
    uint64_t connect);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamRead(
    uint64_t stream, uint8_t *output, size_t capacity,
    uint32_t *state, size_t *length);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamWrite(
    uint64_t stream, const uint8_t *data, size_t length,
    uint32_t *state, size_t *accepted);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamPendingWrite(
    uint64_t stream, size_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamState(
    uint64_t stream, uint32_t *flags);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamShutdownWrite(
    uint64_t stream);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamLocalAddress(
    uint64_t stream, NuppNativeNetAddress *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamPeerAddress(
    uint64_t stream, NuppNativeNetAddress *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamSetNoDelay(
    uint64_t stream, int32_t enabled);
/* Superseded by nuppNativeNetStreamSetKeepAliveMs, whose delay is in
 * milliseconds like every other duration here; kept while the pinned
 * stage-zero bundle names it. */
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamSetKeepAlive(
    uint64_t stream, int32_t enabled, uint32_t delay_seconds);
/* The platform may round the delay to its own granularity, which is whole
 * seconds on most. */
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamSetKeepAliveMs(
    uint64_t stream, int32_t enabled, uint64_t delay_ms);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamRelease(uint64_t stream);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetAddressParse(
    NuppNativeNetSlice host, uint16_t port,
    NuppNativeNetAddress *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetAddressText(
    const NuppNativeNetAddress *address, uint8_t *output,
    size_t capacity, size_t *length);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramCreate(
    const NuppNativeNetDatagramOptions *options, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramPort(
    uint64_t datagram, uint16_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramReceive(
    uint64_t datagram, uint8_t *output, size_t capacity,
    uint32_t *state, size_t *length, NuppNativeNetAddress *address,
    int32_t *truncated);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramSend(
    uint64_t datagram, const NuppNativeNetAddress *address,
    const uint8_t *data, size_t length, uint32_t *state, size_t *sent);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramSetBroadcast(
    uint64_t datagram, int32_t enabled);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramSetMulticastTtl(
    uint64_t datagram, uint32_t ttl);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramSetMulticastLoop(
    uint64_t datagram, int32_t enabled);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramMembership(
    uint64_t datagram, NuppNativeNetSlice group,
    NuppNativeNetSlice interface_address, uint32_t interface_index,
    uint8_t interface_kind, int32_t join);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramRelease(
    uint64_t datagram);
/* The endpoint twins of the address calls above. Text is an IP literal, and an
 * IPv6 endpoint with a scope prints and parses it as `%scope`; parsing also
 * takes an interface name there, such as `fe80::1%lo0`, where the platform can
 * look one up. */
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamLocalEndpoint(
    uint64_t stream, NuppNativeNetEndpoint *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetStreamPeerEndpoint(
    uint64_t stream, NuppNativeNetEndpoint *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetEndpointParse(
    NuppNativeSlice host, uint16_t port, NuppNativeNetEndpoint *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetEndpointText(
    const NuppNativeNetEndpoint *endpoint, uint8_t *output,
    size_t capacity, size_t *length);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramReceiveEndpoint(
    uint64_t datagram, uint8_t *output, size_t capacity,
    uint32_t *state, size_t *length, NuppNativeNetEndpoint *endpoint,
    int32_t *truncated);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetDatagramSendEndpoint(
    uint64_t datagram, const NuppNativeNetEndpoint *endpoint,
    const uint8_t *data, size_t length, uint32_t *state, size_t *sent);
/* Superseded by nuppNativePoll and nuppNativeWait, which these now answer
 * exactly: the network family's generation is the process readiness
 * generation. */
NUPP_NATIVE_EXPORT int32_t nuppNativeNetPoll(uint64_t *generation);
NUPP_NATIVE_EXPORT int32_t nuppNativeNetWait(
    uint64_t generation, uint64_t timeout_ms, uint64_t *output_generation);

/* Present when NUPP_NATIVE_FEATURE_TLS is set. Creating a session consumes
 * its Rust network stream handle on both success and failure. Protocols are a
 * sequence of nonempty names separated and terminated by NUL bytes. */
typedef struct {
    NuppNativeNetSlice hostname;
    NuppNativeNetSlice certificate;
    NuppNativeNetSlice private_key;
    NuppNativeNetSlice authority;
    NuppNativeNetSlice protocols;
    int32_t authority_present;
    int32_t server;
    int32_t verify;
} NuppNativeTlsOptions;

#define NUPP_NATIVE_TLS_HANDSHAKE_PENDING 0u
#define NUPP_NATIVE_TLS_HANDSHAKE_READY 1u
#define NUPP_NATIVE_TLS_READ_DATA 0u
#define NUPP_NATIVE_TLS_READ_PENDING 1u
#define NUPP_NATIVE_TLS_READ_EOF 2u
#define NUPP_NATIVE_TLS_WRITE_ACCEPTED 0u
#define NUPP_NATIVE_TLS_WRITE_PENDING 1u
#define NUPP_NATIVE_TLS_WRITE_CLOSED 2u

NUPP_NATIVE_EXPORT int32_t nuppNativeTlsCreate(
    uint64_t stream, const NuppNativeTlsOptions *options, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsHandshake(
    uint64_t session, uint32_t *state);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsRead(
    uint64_t session, uint8_t *output, size_t capacity,
    uint32_t *state, size_t *length);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsWrite(
    uint64_t session, const uint8_t *data, size_t length,
    uint32_t *state, size_t *accepted);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsFlushed(
    uint64_t session, int32_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsCloseNotify(
    uint64_t session, int32_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsConnected(
    uint64_t session, int32_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsVerified(
    uint64_t session, int32_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsResumed(
    uint64_t session, int32_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsProtocol(
    uint64_t session, uint8_t *output, size_t capacity,
    size_t *length, int32_t *present);
NUPP_NATIVE_EXPORT int32_t nuppNativeTlsRelease(uint64_t session);

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

/* Present when NUPP_NATIVE_FEATURE_HTTP is set. Rust owns every client,
 * transfer, body and worker task; the ABI carries generational handles and
 * copies request/response bytes at each synchronous call boundary. */
typedef NuppNativeSlice NuppNativeHttpSlice;

typedef struct {
    NuppNativeHttpSlice name;
    NuppNativeHttpSlice value;
} NuppNativeHttpHeader;

/* The connect timeout and the three limits must be nonzero. The provider
 * never follows a redirect: a 3xx comes back as a response, and the caller
 * routes each hop and applies max_redirects itself. */
typedef struct {
    uint64_t connect_timeout_ms;
    uint32_t max_redirects;
    uint32_t max_pending_requests;
    uint32_t max_connections;
    uint32_t max_connections_per_host;
    int32_t compressed;
    int32_t has_insecure_hosts;
    int32_t proxy_mode;
    NuppNativeHttpSlice proxy;
    int32_t no_proxy_set;
    NuppNativeHttpSlice no_proxy;
    NuppNativeHttpSlice proxy_credentials;
} NuppNativeHttpClientOptions;

typedef struct {
    NuppNativeHttpSlice url;
    NuppNativeHttpSlice method;
    const NuppNativeHttpHeader *headers;
    size_t header_count;
    NuppNativeHttpSlice body;
    uint32_t body_kind;
    int64_t body_length;
    uint64_t timeout_ms;
    uint64_t stall_timeout_ms;
    uint64_t max_bytes;
    int32_t insecure;
} NuppNativeHttpRequest;

typedef struct {
    uint32_t state;
    uint16_t status;
    uint8_t version;
    size_t url_length;
    size_t headers_length;
} NuppNativeHttpHead;

typedef struct {
    uint64_t transfer;
    uint32_t tokens;
} NuppNativeHttpReady;

/* NuppNativeHttpClientOptions.proxy_mode: the environment's proxies, none,
 * or the one in `proxy`. */
#define NUPP_NATIVE_HTTP_PROXY_ENVIRONMENT 0
#define NUPP_NATIVE_HTTP_PROXY_NONE 1
#define NUPP_NATIVE_HTTP_PROXY_EXPLICIT 2
/* NuppNativeHttpRequest.body_kind. */
#define NUPP_NATIVE_HTTP_BODY_NONE 0u
#define NUPP_NATIVE_HTTP_BODY_INLINE 1u
#define NUPP_NATIVE_HTTP_BODY_UPLOAD 2u
#define NUPP_NATIVE_HTTP_BODY_FILE 3u
/* NuppNativeHttpHead.state, and the states nuppNativeHttpBodyRead writes. */
#define NUPP_NATIVE_HTTP_HEAD_PENDING 0u
#define NUPP_NATIVE_HTTP_HEAD_READY 1u
#define NUPP_NATIVE_HTTP_HEAD_FAILED 2u
#define NUPP_NATIVE_HTTP_BODY_DATA 1u
#define NUPP_NATIVE_HTTP_BODY_PENDING 2u
#define NUPP_NATIVE_HTTP_BODY_EOF 3u
#define NUPP_NATIVE_HTTP_BODY_FAILED 4u
#define NUPP_NATIVE_HTTP_BODY_CLOSED 5u

NUPP_NATIVE_EXPORT int32_t nuppNativeHttpClientCreate(
    const NuppNativeHttpClientOptions *options, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpClientRelease(uint64_t client);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpClientSend(
    uint64_t client, const NuppNativeHttpRequest *request, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpClientPending(
    uint64_t client, size_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpTransferCancel(uint64_t transfer);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpTransferRelease(uint64_t transfer);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpTransferOffer(
    uint64_t transfer, const uint8_t *data, size_t length, int32_t finished,
    int32_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpTransferPollHead(
    uint64_t transfer, NuppNativeHttpHead *output,
    uint8_t *url, size_t url_capacity,
    uint8_t *headers, size_t headers_capacity);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpTransferError(
    uint64_t transfer, uint8_t *output, size_t capacity, size_t *length);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpTransferTakeBody(
    uint64_t transfer, uint64_t *output);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpBodyArm(uint64_t body);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpBodyRead(
    uint64_t body, uint8_t *output, size_t capacity,
    uint32_t *state, size_t *length);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpBodyError(
    uint64_t body, uint8_t *output, size_t capacity, size_t *length);
/* Poll drains the client's ready events without blocking. Every event also
 * advances the process readiness generation, so a caller sleeps in
 * nuppNativeWait and then polls; Wait is superseded by that pair. */
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpClientPoll(
    uint64_t client, NuppNativeHttpReady *output, size_t capacity,
    size_t *count, int32_t *more);
NUPP_NATIVE_EXPORT int32_t nuppNativeHttpClientWait(
    uint64_t client, uint64_t timeout_ms,
    NuppNativeHttpReady *output, size_t capacity,
    size_t *count, int32_t *more);

#ifdef __cplusplus
}
#endif

#endif /* NUPP_NATIVE_H */
