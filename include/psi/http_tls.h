#ifndef PSI_HTTP_TLS_H
#define PSI_HTTP_TLS_H

/* Configure TLS (CA bundle) on a CURL easy handle. The handle is
 * passed as void* to keep this header free of <curl/curl.h>; the
 * implementation casts back to CURL*. Internal callers already
 * include curl/curl.h and pass their CURL* directly (CURL* converts
 * to void* without a cast). */
void psi_http_configure_tls(void *curl);

/* Configure connect timeout, TCP keepalive, and a low-speed idle-stream
 * watchdog (PSI_HTTP_IDLE_TIMEOUT seconds; 0 disables; default 120s).
 * Same void* convention as psi_http_configure_tls. */
void psi_http_configure_resilience(void *curl);

#endif
