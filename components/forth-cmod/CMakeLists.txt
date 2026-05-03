# zForth as an ESP-IDF component.
#
# zForth is a tiny stack-based Forth designed for embedding on small
# microcontrollers. ~1100 lines of C, ~10 KiB compiled, no GC, the
# entire runtime state lives in one fixed allocation that's small
# enough to coexist with mbedTLS handshake buffers (which is where
# Lua and chibi-scheme starve on no-PSRAM ESP32s).
#
# The source is vendored directly under this component (zforth.c +
# zforth.h, MIT-licensed by Ico Doornekamp) since it's so small there's
# no point in fetching at build time.

idf_component_register(
    SRCS zforth.c
    INCLUDE_DIRS "."
    REQUIRES
)

target_compile_options(${COMPONENT_LIB} PRIVATE
    # zforth.c casts between int and pointer freely; ESP-IDF's
    # -Werror=all promotes those to errors.
    -Wno-error=int-conversion
    -Wno-error=incompatible-pointer-types
    -Wno-error=pointer-to-int-cast
    -Wno-error=int-to-pointer-cast
    -Wno-error=unused-function
    -Wno-error=unused-variable
    -Wno-error=unused-but-set-variable
)
