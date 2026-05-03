#include <stdlib.h>
#include <unistd.h>
#include <zlib.h>
#include "psi/common.h"
#include "psi/http_tls.h"

#ifdef PSI_HAVE_EMBEDDED_CA
#include "psi/embedded_data.h"
#endif

#ifndef PSI_CA_BUNDLE_FILE
#define PSI_CA_BUNDLE_FILE ""
#endif

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

void psi_http_configure_tls(CURL *curl) {
    const char *ca_bundle;

    if (curl == NULL)
        return;

    ca_bundle = psi_http_ca_bundle_path();
    if (ca_bundle != NULL) {
        curl_easy_setopt(curl, CURLOPT_CAINFO, ca_bundle);
        return;
    }

#ifdef PSI_HAVE_EMBEDDED_CA
    if (psi_embedded_ca_table[0].src != NULL && psi_embedded_ca_table[0].raw_len > 0u) {
        const struct psi_embedded_data *entry = &psi_embedded_ca_table[0];
        unsigned char *bytes;
        uLongf raw_len;
        struct curl_blob blob;

        bytes = (unsigned char *)malloc(entry->raw_len);
        if (bytes == NULL)
            return;
        raw_len = (uLongf)entry->raw_len;
        if (uncompress(bytes, &raw_len, entry->src, (uLong)entry->len) == Z_OK &&
            raw_len == (uLongf)entry->raw_len) {
            blob.data = (void *)bytes;
            blob.len = entry->raw_len;
            blob.flags = CURL_BLOB_COPY;
            curl_easy_setopt(curl, CURLOPT_CAINFO_BLOB, &blob);
        }
        free(bytes);
    }
#endif
}
