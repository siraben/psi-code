# psi as an ESP-IDF component.
#
# The C/Lua core lives at the root of the psi-coding-agent repo,
# alongside this firmware/components tree. We point the component
# build at $PROJECT_DIR/.. so the existing src/, include/, lua/, and
# scripts/ directories don't need to move.
#
# Capability gates: ESP firmware sets PSI_CAP_FILESYSTEM=0,
# PSI_CAP_PROCESS=0, PSI_CAP_TUI=0, PSI_CAP_HTTP=1, and selects the
# esp_http_client backend via PSI_HTTP_BACKEND_CURL=0. See
# include/psi/* for the full list.

set(PSI_ROOT "${CMAKE_CURRENT_LIST_DIR}/../..")

# ---- Embed tool (host build) ----
# scripts/embed.c is a host-arch compiler away from being usable
# during cross-compile. We invoke the host-installed gcc + zlib via
# CMake's add_custom_command so the build node's toolchain produces
# the helper, not the xtensa-esp-elf-gcc cross compiler.
set(PSI_EMBED_TOOL "${CMAKE_BINARY_DIR}/psi_embed")
add_custom_command(
    OUTPUT "${PSI_EMBED_TOOL}"
    COMMAND $ENV{HOST_CC} -O2 -o "${PSI_EMBED_TOOL}" "${PSI_ROOT}/scripts/embed.c" -lz
    DEPENDS "${PSI_ROOT}/scripts/embed.c"
    COMMENT "Building psi embed helper for host"
    VERBATIM
)

# ---- Embedded blobs ----
file(GLOB_RECURSE PSI_LUA_SOURCES "${PSI_ROOT}/lua/*.lua")
list(SORT PSI_LUA_SOURCES)
set(PSI_EMBED_LUA "${CMAKE_BINARY_DIR}/embedded_lua.c")
add_custom_command(
    OUTPUT "${PSI_EMBED_LUA}"
    COMMAND ${CMAKE_COMMAND} -E env "${PSI_EMBED_TOOL}"
            "${PSI_ROOT}/lua/boot.lua"
            "${PSI_ROOT}/lua/boot-esp.lua"
            ${PSI_LUA_SOURCES}
            > "${PSI_EMBED_LUA}"
    DEPENDS "${PSI_EMBED_TOOL}" ${PSI_LUA_SOURCES}
        "${PSI_ROOT}/lua/boot.lua" "${PSI_ROOT}/lua/boot-esp.lua"
    COMMENT "Embedding psi Lua sources"
    VERBATIM
)

set(PSI_DOC_SOURCES
    "${PSI_ROOT}/README.md"
    "${PSI_ROOT}/docs/architecture.md"
    "${PSI_ROOT}/docs/extensions.md"
    "${PSI_ROOT}/docs/port-status.md"
    "${PSI_ROOT}/docs/portability.md"
    "${PSI_ROOT}/docs/providers.md"
)
set(PSI_EMBED_DOCS "${CMAKE_BINARY_DIR}/embedded_docs.c")
add_custom_command(
    OUTPUT "${PSI_EMBED_DOCS}"
    COMMAND "${PSI_EMBED_TOOL}" --table=psi_embedded_docs_table --raw-keys
            ${PSI_DOC_SOURCES} > "${PSI_EMBED_DOCS}"
    DEPENDS "${PSI_EMBED_TOOL}" ${PSI_DOC_SOURCES}
    COMMENT "Embedding psi docs"
    VERBATIM
)

set(PSI_EMBED_HTML "${CMAKE_BINARY_DIR}/embedded_html.c")
add_custom_command(
    OUTPUT "${PSI_EMBED_HTML}"
    COMMAND "${PSI_EMBED_TOOL}" --table=psi_embedded_html_table
            --key=index.html "${PSI_ROOT}/assets/web/index.html"
            > "${PSI_EMBED_HTML}"
    DEPENDS "${PSI_EMBED_TOOL}" "${PSI_ROOT}/assets/web/index.html"
    COMMENT "Embedding psi web SPA"
    VERBATIM
)

# ---- C sources ----
# We deliberately exclude src/runtime/ (CLI/TUI dispatcher, libedit,
# argtable3) and src/main.c (POSIX entrypoint). The ESP backend in
# src/backend/esp/ provides app_main + WS server.
set(PSI_C_SOURCES
    "${PSI_ROOT}/src/core/abort.c"
    "${PSI_ROOT}/src/core/common.c"
    "${PSI_ROOT}/src/core/http_async.c"
    "${PSI_ROOT}/src/core/http_buffered.c"
    "${PSI_ROOT}/src/core/http_tls.c"
    "${PSI_ROOT}/src/core/process.c"
    "${PSI_ROOT}/src/core/session.c"
    "${PSI_ROOT}/src/lua/vm.c"
    "${PSI_ROOT}/src/backend/esp/esp_main.c"
    "${PSI_ROOT}/src/backend/esp/esp_abort.c"
    "${PSI_ROOT}/src/backend/esp/esp_http.c"
    "${PSI_ROOT}/src/backend/esp/esp_observer.c"
    "${PSI_ROOT}/src/backend/esp/esp_ws_server.c"
    ${PSI_EMBED_LUA}
    ${PSI_EMBED_DOCS}
    ${PSI_EMBED_HTML}
)

idf_component_register(
    SRCS ${PSI_C_SOURCES}
    INCLUDE_DIRS "${PSI_ROOT}/include" "${PSI_ROOT}/src/backend/esp"
    REQUIRES
        cjson
        esp_event
        esp_http_client
        esp_http_server
        esp_netif
        esp_wifi
        mbedtls
        mdns
        nvs_flash
    PRIV_REQUIRES
        lua-cmod
)

# Capability gates and HTTP backend selection. -DPSI_CAP_FILESYSTEM=0
# strips the libcurl-style file primitives entirely; PSI_HTTP_BACKEND_CURL=0
# routes the HTTP layer through esp_http_client + mbedTLS.
target_compile_definitions(${COMPONENT_LIB} PRIVATE
    PSI_CAP_FILESYSTEM=0
    PSI_CAP_PROCESS=0
    PSI_CAP_TUI=0
    PSI_CAP_ENV=0
    PSI_CAP_STDIO=0
    PSI_CAP_RAMFS=1
    PSI_CAP_HTTP=1
    PSI_CAP_EMBEDDED_RESOURCES=1
    PSI_HTTP_BACKEND_CURL=0
    PSI_ENABLE_TUI=0
    PSI_ENABLE_ANSI=0
    PSI_ENABLE_COLOR=0
    PSI_ENABLE_REPL_EDITLINE=0
    PSI_LUA_BOOT_FILE=""
)

# The desktop tree compiles with -std=c89 -pedantic -Wall -Wextra
# -Werror. The ESP-IDF headers used by esp_*.c require C99, so relax
# just those translation units. The bodies still use C89 syntax to
# match the rest of the project.
set_source_files_properties(
    "${PSI_ROOT}/src/backend/esp/esp_main.c"
    "${PSI_ROOT}/src/backend/esp/esp_http.c"
    "${PSI_ROOT}/src/backend/esp/esp_observer.c"
    "${PSI_ROOT}/src/backend/esp/esp_ws_server.c"
    PROPERTIES COMPILE_FLAGS "-std=gnu99"
)
