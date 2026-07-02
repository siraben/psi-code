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
 * half-open connection fails in bounded time. */
#define PSI_HTTP_IDLE_TIMEOUT_SECS 120L
#define PSI_HTTP_LOW_SPEED_LIMIT 1L
#define PSI_HTTP_CONNECT_TIMEOUT_SECS 30L
#define PSI_HTTP_TCP_KEEPIDLE_SECS 30L
#define PSI_HTTP_TCP_KEEPINTVL_SECS 15L

static int psi_http_path_readable(const char *path) {
    return path != NULL && path[0] != '\0' && access(path, R_OK) == 0;
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

static long psi_http_idle_timeout_secs(void) {
    const char *value = getenv("PSI_HTTP_IDLE_TIMEOUT");
    char *end;
    long secs;

    if (value == NULL || value[0] == '\0')
        return PSI_HTTP_IDLE_TIMEOUT_SECS;
    end = NULL;
    secs = strtol(value, &end, 10);
    if (end == value || *end != '\0' || secs < 0l)
        return PSI_HTTP_IDLE_TIMEOUT_SECS;
    return secs;
}

void psi_http_configure_resilience(void *curl) {
    CURL *handle = (CURL *)curl;
    long idle_secs;

    if (handle == NULL)
        return;

    /* Bound the TCP/TLS handshake so a black-holed host fails fast. */
    curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, PSI_HTTP_CONNECT_TIMEOUT_SECS);

    /* Let the OS detect a dead peer on an idle connection. KEEPIDLE/KEEPINTVL
     * are honored where supported (Linux, macOS) and ignored elsewhere. */
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPIDLE, PSI_HTTP_TCP_KEEPIDLE_SECS);
    curl_easy_setopt(handle, CURLOPT_TCP_KEEPINTVL, PSI_HTTP_TCP_KEEPINTVL_SECS);

    idle_secs = psi_http_idle_timeout_secs();
    if (idle_secs > 0l) {
        curl_easy_setopt(handle, CURLOPT_LOW_SPEED_LIMIT, PSI_HTTP_LOW_SPEED_LIMIT);
        curl_easy_setopt(handle, CURLOPT_LOW_SPEED_TIME, idle_secs);
    }
}
