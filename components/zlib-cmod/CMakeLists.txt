# zlib as an ESP-IDF component.
#
# ESP-IDF v5.5 turned its built-in zlib into a managed component
# (espressif/zlib), which the Nix sandbox can't fetch from
# components.espressif.com. We vendor zlib instead: the Nix flake
# unpacks zlib-1.3.1 and points ZLIB_SRC_DIR at the result before
# invoking idf.py build.
#
# The component exposes a target named zlib (matching the component
# name) so the psi component's REQUIRES list can reference it as
# either zlib or zlib-cmod (we use REQUIRES zlib-cmod in psi/).

if(NOT DEFINED ENV{ZLIB_SRC_DIR})
    message(FATAL_ERROR "ZLIB_SRC_DIR not set. Pass the path to a zlib source tree.")
endif()
set(Z_SRC "$ENV{ZLIB_SRC_DIR}")

# Drop the gz* sources: they need POSIX file streams that ESP-IDF
# only partially provides, and psi never reads gzip files anyway.
# What's left is enough for compress()/uncompress(), which is all the
# embedded-blob inflater calls.
set(ZLIB_SOURCES
    "${Z_SRC}/adler32.c"
    "${Z_SRC}/crc32.c"
    "${Z_SRC}/deflate.c"
    "${Z_SRC}/infback.c"
    "${Z_SRC}/inffast.c"
    "${Z_SRC}/inflate.c"
    "${Z_SRC}/inftrees.c"
    "${Z_SRC}/trees.c"
    "${Z_SRC}/zutil.c"
    "${Z_SRC}/compress.c"
    "${Z_SRC}/uncompr.c"
)

idf_component_register(
    SRCS ${ZLIB_SOURCES}
    INCLUDE_DIRS "${Z_SRC}"
    REQUIRES
)

target_compile_options(${COMPONENT_LIB} PRIVATE
    # Don't enable Z_SOLO: that compiles out zutil.c's default
    # zcalloc/zcfree, which uncompress() needs. ESP-IDF newlib has
    # malloc()/calloc(), so the default allocators just work.
    -Wno-implicit-function-declaration
    -Wno-deprecated-non-prototype
)
