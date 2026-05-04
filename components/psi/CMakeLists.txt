# psi as an ESP-IDF component.
#
# The C/Lua core lives at the root of the psi-coding-agent repo,
# alongside this firmware/components tree. We point the component
# build at $PROJECT_DIR/.. so the existing src/, include/, and
# scripts/ directories don't need to move.
#
# The desktop psi build uses Lua heavily; this ESP build does not.
# zforth is the on-chip extension language (see components/forth-cmod
# and src/backend/esp/esp_forth.c) and the C agent loop in
# esp_agent.c is what drives Anthropic. There is no Lua VM, no
# embedded module graph, no lua-cmod dependency.

set(PSI_ROOT "${CMAKE_CURRENT_LIST_DIR}/../..")

# PSI_INCLUDE_SPA controls whether the firmware embeds the chat SPA
# at /. Default ON so the firmware is self-contained — open the
# device's IP in a browser and chat. Turn OFF when only the host
# frontend dashboard talks to the chip.
option(PSI_INCLUDE_SPA "Embed the chat SPA into the firmware" ON)

# PSI_GPIO_INTROSPECTION exposes /gpio for the host dashboard's pin
# grid. ON by default; turn OFF on real hardware where you'd measure
# pins with a probe instead.
option(PSI_GPIO_INTROSPECTION "Expose /gpio endpoint for the host dashboard pin grid" ON)

# PSI_USE_FORTH_PROMPT builds the agent's system prompt at boot via
# zforth + a few C foreign procs. ON by default — zforth is the
# extension language and the prompt-builder using it keeps the path
# uniform. Turn OFF to use the baked-in C string fallback.
option(PSI_USE_FORTH_PROMPT "Build the system prompt with zforth at boot" ON)

set(PSI_EMBED_TOOL "${CMAKE_CURRENT_BINARY_DIR}/psi_embed")
set(PSI_EMBED_HTML "${CMAKE_CURRENT_BINARY_DIR}/embedded_html.c")

# ---- C sources ----
# We deliberately exclude src/runtime/ (CLI/TUI dispatcher, libedit,
# argtable3), src/main.c (POSIX entrypoint), and src/lua/vm.c (the
# desktop Lua VM, which doesn't fit on a no-PSRAM ESP32). The ESP
# backend in src/backend/esp/ provides app_main + WS server, and
# src/core/embedded_inflate.c supplies the no-zlib inflater the SPA
# loader needs (vm.c carries the zlib-backed version on desktop).
set(PSI_C_SOURCES
    "${PSI_ROOT}/src/core/abort.c"
    "${PSI_ROOT}/src/core/common.c"
    "${PSI_ROOT}/src/core/embedded_inflate.c"
    "${PSI_ROOT}/src/core/http_async.c"
    "${PSI_ROOT}/src/core/http_buffered.c"
    "${PSI_ROOT}/src/core/http_tls.c"
    "${PSI_ROOT}/src/core/process.c"
    "${PSI_ROOT}/src/core/session.c"
    "${PSI_ROOT}/src/backend/esp/esp_main.c"
    "${PSI_ROOT}/src/backend/esp/esp_abort.c"
    "${PSI_ROOT}/src/backend/esp/esp_agent.c"
    "${PSI_ROOT}/src/backend/esp/esp_tools.c"
    "${PSI_ROOT}/src/backend/esp/esp_http.c"
    "${PSI_ROOT}/src/backend/esp/esp_observer.c"
    "${PSI_ROOT}/src/backend/esp/esp_ws_server.c"
    "${PSI_ROOT}/src/backend/esp/esp_forth.c"
    "${PSI_ROOT}/src/backend/esp/esp_ble.c"
    ${PSI_EMBED_HTML}
)

idf_component_register(
    SRCS ${PSI_C_SOURCES}
    INCLUDE_DIRS "${PSI_ROOT}/include" "${PSI_ROOT}/src/backend/esp"
    REQUIRES
        json
        esp_event
        esp_eth
        esp_wifi
        bt
        esp_http_client
        esp_http_server
        esp-tls
        esp_netif
        esp_driver_gpio
        esp_timer
        mbedtls
        nvs_flash
    PRIV_REQUIRES
        forth-cmod
)

# Capability gates. PSI_HTTP_BACKEND_CURL=0 routes the HTTP layer
# through esp_http_client + mbedTLS (vs libcurl on desktop).
# PSI_NO_ZLIB strips zlib and switches embedded_inflate.c to its
# memcpy-only path (the firmware's embed pipeline always uses
# --no-compress, so raw_len == len and we never actually inflate).
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
    PSI_NO_ZLIB=1
)

if(PSI_INCLUDE_SPA)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PSI_INCLUDE_SPA=1)
else()
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PSI_INCLUDE_SPA=0)
endif()

if(PSI_GPIO_INTROSPECTION)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PSI_GPIO_INTROSPECTION=1)
else()
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PSI_GPIO_INTROSPECTION=0)
endif()

if(PSI_USE_FORTH_PROMPT)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PSI_USE_FORTH_PROMPT=1)
else()
    target_compile_definitions(${COMPONENT_LIB} PRIVATE PSI_USE_FORTH_PROMPT=0)
endif()

# Mark the generated source so ESP-IDF doesn't complain about a
# missing file at idf_component_register time. The custom command
# below populates it during the main build.
set_source_files_properties(${PSI_EMBED_HTML} PROPERTIES GENERATED TRUE)

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

# ---- Embedded SPA blob ----
# scripts/embed.c emits a static C array; --no-compress makes it raw
# bytes (no DEFLATE), which the runtime memcpy's into a heap buffer
# at boot. ~14 KiB of flash for the chat UI.
if(PSI_INCLUDE_SPA)
    add_custom_command(
        OUTPUT "${PSI_EMBED_HTML}"
        COMMAND "${PSI_EMBED_TOOL}" --no-compress --table=psi_embedded_html_table
                --key=index.html assets/web/index.html
                > "${PSI_EMBED_HTML}"
        WORKING_DIRECTORY "${PSI_ROOT}"
        DEPENDS "${PSI_EMBED_TOOL}" "${PSI_ROOT}/assets/web/index.html"
        COMMENT "Embedding psi web SPA (uncompressed)"
        VERBATIM
    )
else()
    add_custom_command(
        OUTPUT "${PSI_EMBED_HTML}"
        COMMAND ${CMAKE_COMMAND} -E echo "/* auto-generated stub — SPA disabled */"
            > "${PSI_EMBED_HTML}"
        COMMAND ${CMAKE_COMMAND} -E echo "#include <stddef.h>"
            >> "${PSI_EMBED_HTML}"
        COMMAND ${CMAKE_COMMAND} -E echo "#include \"psi/embedded_data.h\""
            >> "${PSI_EMBED_HTML}"
        COMMAND ${CMAKE_COMMAND} -E echo "const struct psi_embedded_data psi_embedded_html_table[] = { { NULL, NULL, 0u, 0u } };"
            >> "${PSI_EMBED_HTML}"
        COMMENT "Stubbing psi web SPA table (PSI_INCLUDE_SPA=OFF)"
        VERBATIM
    )
endif()
