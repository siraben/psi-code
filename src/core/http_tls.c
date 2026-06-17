/* TLS bundle discovery for libcurl. Tries a small list of env vars and
 * common system paths, falls back to the embedded CA bundle when one
 * was compiled in (PSI_HAVE_EMBEDDED_CA). Static binaries shipped
 * without a host certificate store rely on the embedded path. */

#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>
#include <curl/curl.h>
#include <zlib.h>
#include "psi/common.h"
#include "psi/http_tls.h"

#ifdef PSI_HAVE_EMBEDDED_CA
#include "psi/embedded_data.h"
#endif

#ifndef PSI_CA_BUNDLE_FILE
#define PSI_CA_BUNDLE_FILE ""
#endif

/* Connection-resilience defaults. The watchdog aborts a transfer
 * averaging below PSI_HTTP_LOW_SPEED_LIMIT bytes/s for the idle window:
 * loose enough for a slow-but-live stream, tight enough that a dead
 * half-open connection fails in bounded time. Connect and idle windows
 * are tunable in milliseconds via env vars; the legacy
 * PSI_HTTP_IDLE_TIMEOUT (seconds) var is still honored. */
#define PSI_HTTP_LOW_SPEED_LIMIT 1L
#define PSI_HTTP_CONNECT_TIMEOUT_DEFAULT_MS 15000L
#define PSI_HTTP_IDLE_TIMEOUT_DEFAULT_MS 300000L
#define PSI_HTTP_TCP_KEEPIDLE_SECS 30L
#define PSI_HTTP_TCP_KEEPINTVL_SECS 15L

static int psi_http_path_readable(const char *path) {
    return path != NULL && path[0] != '\0' && access(path, R_OK) == 0;
}

static long psi_http_env_long(const char *name, long fallback) {
    const char *value;
    char *end;
    long parsed;

    value = getenv(name);
    if (value == NULL || value[0] == '\0')
        return fallback;
    parsed = strtol(value, &end, 10);
    if (end == value || parsed < 0L)
        return fallback;
    return parsed;
}

static long psi_http_ceil_seconds(long ms) {
    if (ms <= 0L)
        return 0L;
    return (ms + 999L) / 1000L;
}

static const char *psi_http_ca_bundle_path(void) {
    static const char *const env_names[] = {
        "PSI_CA_BUNDLE",
        "CURL_CA_BUNDLE",
        "SSL_CERT_FILE",
        "NIX_SSL_CERT_FILE",
    };
    size_t i;

    for (i = 0u; i < sizeof(env_names) / sizeof(env_names[0]); i++) {
        const char *value = getenv(env_names[i]);
        if (psi_http_path_readable(value))
            return value;
    }
    if (psi_http_path_readable(PSI_CA_BUNDLE_FILE))
        return PSI_CA_BUNDLE_FILE;
    return NULL;
}

/* TLS answer resolved once per process, under pthread_once (streaming
 * helper threads call this too). Changing CURL_CA_BUNDLE mid-process
 * has no effect; acceptable. */
static pthread_once_t psi_http_tls_once = PTHREAD_ONCE_INIT;
static char *psi_http_tls_bundle_path = NULL;
#ifdef PSI_HAVE_EMBEDDED_CA
static unsigned char *psi_http_tls_embedded_bytes = NULL;
static size_t psi_http_tls_embedded_len = 0u;
#endif

static void psi_http_tls_resolve_cb(void) {
    const char *ca_bundle;

    ca_bundle = psi_http_ca_bundle_path();
    if (ca_bundle != NULL) {
        /* Copy: getenv() storage may be invalidated by later
         * setenv/putenv calls on other threads. */
        psi_http_tls_bundle_path = psi_strdup(ca_bundle);
        return;
    }

#ifdef PSI_HAVE_EMBEDDED_CA
    if (psi_embedded_ca_table[0].src != NULL && psi_embedded_ca_table[0].raw_len > 0u) {
        const struct psi_embedded_data *entry = &psi_embedded_ca_table[0];
        unsigned char *bytes;
        uLongf raw_len;

        bytes = (unsigned char *)malloc(entry->raw_len);
        if (bytes == NULL)
            return;
        raw_len = (uLongf)entry->raw_len;
        if (uncompress(bytes, &raw_len, entry->src, (uLong)entry->len) == Z_OK &&
            raw_len == (uLongf)entry->raw_len) {
            /* Never freed: process-lifetime cache handed to curl
             * per handle via CURL_BLOB_COPY. */
            psi_http_tls_embedded_bytes = bytes;
            psi_http_tls_embedded_len = entry->raw_len;
        } else {
            free(bytes);
        }
    }
#endif
}

void psi_http_configure_tls(void *curl) {
    CURL *handle = (CURL *)curl;

    if (handle == NULL)
        return;

    pthread_once(&psi_http_tls_once, psi_http_tls_resolve_cb);

    if (psi_http_tls_bundle_path != NULL) {
        curl_easy_setopt(handle, CURLOPT_CAINFO, psi_http_tls_bundle_path);
        return;
    }

#ifdef PSI_HAVE_EMBEDDED_CA
    if (psi_http_tls_embedded_bytes != NULL && psi_http_tls_embedded_len > 0u) {
        struct curl_blob blob;

        blob.data = (void *)psi_http_tls_embedded_bytes;
        blob.len = psi_http_tls_embedded_len;
        blob.flags = CURL_BLOB_COPY;
        curl_easy_setopt(handle, CURLOPT_CAINFO_BLOB, &blob);
    }
#endif
}

/* Idle-stream watchdog window in seconds. Prefers the millisecond override
 * PSI_HTTP_IDLE_TIMEOUT_MS, then the legacy PSI_HTTP_IDLE_TIMEOUT (seconds),
 * then the default. 0 disables the watchdog. */
static long psi_http_idle_timeout_secs(void) {
    long ms;
    const char *value;
    char *end;
    long secs;

    ms = psi_http_env_long("PSI_HTTP_IDLE_TIMEOUT_MS", -1L);
    if (ms >= 0L)
        return psi_http_ceil_seconds(ms);

    value = getenv("PSI_HTTP_IDLE_TIMEOUT");
    if (value == NULL || value[0] == '\0')
        return psi_http_ceil_seconds(PSI_HTTP_IDLE_TIMEOUT_DEFAULT_MS);
    end = NULL;
    secs = strtol(value, &end, 10);
    if (end == value || *end != '\0' || secs < 0l)
        return psi_http_ceil_seconds(PSI_HTTP_IDLE_TIMEOUT_DEFAULT_MS);
    return secs;
}

void psi_http_configure_resilience(void *curl) {
    CURL *handle = (CURL *)curl;
    long connect_ms;
    long idle_secs;
    long total_ms;

    if (handle == NULL)
        return;

    /* Bound the TCP/TLS handshake so a black-holed host fails fast.
     * Tunable in milliseconds via PSI_HTTP_CONNECT_TIMEOUT_MS. */
    connect_ms =
        psi_http_env_long("PSI_HTTP_CONNECT_TIMEOUT_MS", PSI_HTTP_CONNECT_TIMEOUT_DEFAULT_MS);
    if (connect_ms > 0L)
        curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT_MS, connect_ms);

    /* Let the OS detect a dead peer on an idle connection. KEEPIDLE/KEEPINTVL
     * are honored where supported (Linux, macOS) and ignored elsewhere. */
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPIDLE, PSI_HTTP_TCP_KEEPIDLE_SECS);
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPINTVL, PSI_HTTP_TCP_KEEPINTVL_SECS);

    /* Abort a connected-but-idle transfer that stalls below the low-speed
     * floor for the idle window. */
    idle_secs = psi_http_idle_timeout_secs();
    if (idle_secs > 0L) {
        curl_easy_setopt(handle, CURLOPT_LOW_SPEED_LIMIT, PSI_HTTP_LOW_SPEED_LIMIT);
        curl_easy_setopt(handle, CURLOPT_LOW_SPEED_TIME, idle_secs);
    }

    /* Optional hard deadline for the whole request (0 disables). Useful for
     * short metadata calls, risky for long streaming turns. */
    total_ms = psi_http_env_long("PSI_HTTP_TOTAL_TIMEOUT_MS", 0L);
    if (total_ms > 0L)
        curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, total_ms);
}
