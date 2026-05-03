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

# Generated blob paths. These live under the component's build dir so
# ESP-IDF treats them like ordinary sources. The custom commands that
# create them are only registered in the main build pass — ESP-IDF
# also evaluates this CMakeLists in script mode (CMAKE_BUILD_EARLY_EXPANSION),
# where add_custom_command is forbidden.
set(PSI_EMBED_TOOL "${CMAKE_CURRENT_BINARY_DIR}/psi_embed")
set(PSI_EMBED_LUA  "${CMAKE_CURRENT_BINARY_DIR}/embedded_lua.c")
set(PSI_EMBED_DOCS "${CMAKE_CURRENT_BINARY_DIR}/embedded_docs.c")
set(PSI_EMBED_HTML "${CMAKE_CURRENT_BINARY_DIR}/embedded_html.c")

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
        json
        esp_event
        esp_eth
        esp_http_client
        esp_http_server
        esp-tls
        esp_netif
        esp_wifi
        mbedtls
        nvs_flash
    PRIV_REQUIRES
        lua-cmod
        zlib-cmod
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

# ESP-IDF v5.5+ uses C23-ish dialect for its headers; we let the
# component-default flags through and only ensure psi's *own* sources
# (the C89-clean ones) compile under whatever ESP-IDF picks. The
# backend src/backend/esp/*.c bodies are C89-syntax-compatible so
# they build under any -std=gnu1x.

# Mark the generated sources so ESP-IDF doesn't complain about
# missing files at idf_component_register time. The custom commands
# below populate them during the main build.
set_source_files_properties(
    ${PSI_EMBED_LUA} ${PSI_EMBED_DOCS} ${PSI_EMBED_HTML}
    PROPERTIES GENERATED TRUE
)

# Skip the rest in script-mode (component_get_requirements) — only
# the main build can run add_custom_command and add_dependencies.
if(CMAKE_BUILD_EARLY_EXPANSION)
    return()
endif()

# ---- Embed tool (host build) ----
add_custom_command(
    OUTPUT "${PSI_EMBED_TOOL}"
    COMMAND $ENV{HOST_CC} -O2 -o "${PSI_EMBED_TOOL}" "${PSI_ROOT}/scripts/embed.c" -lz
    DEPENDS "${PSI_ROOT}/scripts/embed.c"
    COMMENT "Building psi embed helper for host"
    VERBATIM
)

# ---- Embedded blobs ----
# scripts/embed.c keys Lua modules by stripping the leading "lua/"
# segment of each input path. To produce the canonical "psi/foo.lua"
# keys (matching what the desktop Makefile generates), we run the
# embed tool from PSI_ROOT and pass path arguments relative to it.
file(GLOB_RECURSE _psi_lua_abs "${PSI_ROOT}/lua/*.lua")
list(SORT _psi_lua_abs)
set(PSI_LUA_RELATIVE)
foreach(_p IN LISTS _psi_lua_abs)
    file(RELATIVE_PATH _r "${PSI_ROOT}" "${_p}")
    list(APPEND PSI_LUA_RELATIVE "${_r}")
endforeach()
add_custom_command(
    OUTPUT "${PSI_EMBED_LUA}"
    COMMAND "${PSI_EMBED_TOOL}" ${PSI_LUA_RELATIVE} > "${PSI_EMBED_LUA}"
    WORKING_DIRECTORY "${PSI_ROOT}"
    DEPENDS "${PSI_EMBED_TOOL}" ${_psi_lua_abs}
    COMMENT "Embedding psi Lua sources"
    VERBATIM
)

set(PSI_DOC_RELATIVE
    "README.md"
    "docs/architecture.md"
    "docs/extensions.md"
    "docs/port-status.md"
    "docs/portability.md"
    "docs/providers.md"
)
add_custom_command(
    OUTPUT "${PSI_EMBED_DOCS}"
    COMMAND "${PSI_EMBED_TOOL}" --table=psi_embedded_docs_table --raw-keys
            ${PSI_DOC_RELATIVE} > "${PSI_EMBED_DOCS}"
    WORKING_DIRECTORY "${PSI_ROOT}"
    DEPENDS "${PSI_EMBED_TOOL}"
    COMMENT "Embedding psi docs"
    VERBATIM
)

add_custom_command(
    OUTPUT "${PSI_EMBED_HTML}"
    COMMAND "${PSI_EMBED_TOOL}" --table=psi_embedded_html_table
            --key=index.html assets/web/index.html
            > "${PSI_EMBED_HTML}"
    WORKING_DIRECTORY "${PSI_ROOT}"
    DEPENDS "${PSI_EMBED_TOOL}" "${PSI_ROOT}/assets/web/index.html"
    COMMENT "Embedding psi web SPA"
    VERBATIM
)

# Tie the generated blobs to the component build target so ninja
# orders the embed step correctly.
add_custom_target(psi_generate_embeds DEPENDS
    ${PSI_EMBED_LUA} ${PSI_EMBED_DOCS} ${PSI_EMBED_HTML})
add_dependencies(${COMPONENT_LIB} psi_generate_embeds)
