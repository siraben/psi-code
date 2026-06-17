#ifndef PSI_HTTP_TLS_H
#define PSI_HTTP_TLS_H

/* Configure shared libcurl options on a CURL easy handle. Handles are
 * passed as void* to keep this header free of <curl/curl.h>; the
 * implementation casts back to CURL*. Internal callers already
 * include curl/curl.h and pass their CURL* directly (CURL* converts
 * to void* without a cast). */
void psi_http_configure_tls(void *curl);

/* Configure connect timeout, TCP keepalive, a low-speed idle-stream
 * watchdog, and an optional total-request deadline. Tunable via
 * PSI_HTTP_CONNECT_TIMEOUT_MS, PSI_HTTP_IDLE_TIMEOUT_MS (0 disables;
 * default 300000; legacy PSI_HTTP_IDLE_TIMEOUT seconds still honored),
 * and PSI_HTTP_TOTAL_TIMEOUT_MS (0 disables). Same void* convention as
 * psi_http_configure_tls. */
void psi_http_configure_resilience(void *curl);

#endif
