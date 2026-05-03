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
# PSI_INCLUDE_SPA controls whether the firmware embeds the chat SPA
# at /. Default ON so `nix build .#firmware` keeps producing a
# self-contained image that can be opened directly in a browser.
# Turn OFF (idf.py build -DPSI_INCLUDE_SPA=OFF) when the firmware is
# only ever talked to through the host frontend dashboard
# (`apps.esp-frontend`), which serves its own UI and proxies the WS.
# Saves ~14 KiB of flash + the inflate codepath at boot.
option(PSI_INCLUDE_SPA "Embed the chat SPA into the firmware" ON)

# PSI_GPIO_INTROSPECTION exposes the /gpio HTTP endpoint and the
# shadow state behind it (configured mode + last commanded level for
# every pin). The host dashboard polls this at 2 Hz to render a live
# pin grid. Useful in QEMU where there's no physical scope. On real
# hardware you'd measure pins directly, so default OFF saves the
# 40-byte shadow + a small handler. The flake sets ON for the QEMU
# firmware image; pass -DPSI_GPIO_INTROSPECTION=OFF for production.
option(PSI_GPIO_INTROSPECTION "Expose /gpio endpoint for the host dashboard pin grid" ON)

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
    "${PSI_ROOT}/src/backend/esp/esp_agent.c"
    "${PSI_ROOT}/src/backend/esp/esp_tools.c"
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
        esp_driver_gpio
        esp_timer
        mbedtls
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
# segment of each input path; we run from PSI_ROOT with relative
# paths so the keys come out as "psi/foo.lua" instead of absolute
# build-tree paths.
#
# --no-compress emits the source verbatim (len == raw_len). The
# runtime inflater memcpy's the bytes instead of allocating an
# inflate state + intermediate buffer; on ESP32 the heap pressure
# from compressed loads bricked module loading mid-boot. Trades ~700
# KiB of flash for a much simpler load path; the 2 MiB factory
# partition has plenty of headroom.
#
# We also drop unused modules: TUI, slash commands, alternative
# providers, markdown rendering, theming, prompt templates,
# extensions. A real-hardware build that wants those can extend
# PSI_LUA_RELATIVE here.
set(PSI_LUA_RELATIVE
    lua/boot.lua
    lua/boot-esp.lua
    lua/psi/agent_control.lua
    lua/psi/agent_session.lua
    lua/psi/api_registry.lua
    lua/psi/context.lua
    lua/psi/diff.lua
    lua/psi/event_bus.lua
    lua/psi/file_mutation_queue.lua
    lua/psi/json_pure.lua
    lua/psi/path_utils.lua
    lua/psi/prelude.lua
    lua/psi/prompt.lua
    lua/psi/provider_loop.lua
    lua/psi/providers/anthropic.lua
    lua/psi/providers/openai_compat.lua
    lua/psi/ramfs.lua
    lua/psi/records.lua
    lua/psi/resource_loader.lua
    lua/psi/sched.lua
    lua/psi/session_manager.lua
    lua/psi/settings_manager.lua
    lua/psi/storage.lua
    lua/psi/stream_parser.lua
    lua/psi/thinking.lua
    lua/psi/tool_helpers.lua
    lua/psi/tool_registry.lua
    lua/psi/tool_shell.lua
    lua/psi/tools.lua
    lua/psi/tools/edit.lua
    lua/psi/tools/ls.lua
    lua/psi/tools/lua.lua
    lua/psi/tools/read.lua
    lua/psi/tools/write.lua
    lua/psi/transform_messages.lua
    lua/psi/truncate.lua
    lua/psi/auth_storage.lua
)
set(_psi_lua_abs)
foreach(_r IN LISTS PSI_LUA_RELATIVE)
    list(APPEND _psi_lua_abs "${PSI_ROOT}/${_r}")
endforeach()
add_custom_command(
    OUTPUT "${PSI_EMBED_LUA}"
    COMMAND "${PSI_EMBED_TOOL}" --no-compress ${PSI_LUA_RELATIVE} > "${PSI_EMBED_LUA}"
    WORKING_DIRECTORY "${PSI_ROOT}"
    DEPENDS "${PSI_EMBED_TOOL}" ${_psi_lua_abs}
    COMMENT "Embedding psi Lua sources (uncompressed)"
    VERBATIM
)

# Docs are not used by the firmware agent; emit a stub table so
# psi_embedded_docs_table is defined for the linker. (The C side
# references it from lfn_embedded_doc.)
add_custom_command(
    OUTPUT "${PSI_EMBED_DOCS}"
    COMMAND ${CMAKE_COMMAND} -E echo "/* auto-generated stub */"
        > "${PSI_EMBED_DOCS}"
    COMMAND ${CMAKE_COMMAND} -E echo "#include <stddef.h>"
        >> "${PSI_EMBED_DOCS}"
    COMMAND ${CMAKE_COMMAND} -E echo "#include \"psi/embedded_data.h\""
        >> "${PSI_EMBED_DOCS}"
    COMMAND ${CMAKE_COMMAND} -E echo "const struct psi_embedded_data psi_embedded_docs_table[] = { { NULL, NULL, 0u, 0u } };"
        >> "${PSI_EMBED_DOCS}"
    COMMENT "Stubbing psi docs table (firmware doesn't embed docs)"
    VERBATIM
)

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
    # Empty stub: linker still resolves psi_embedded_html_table, but
    # the / handler is compiled out so the table is never consulted.
    add_custom_command(
        OUTPUT "${PSI_EMBED_HTML}"
        COMMAND ${CMAKE_COMMAND} -E echo "/* PSI_INCLUDE_SPA=0 stub */"
            > "${PSI_EMBED_HTML}"
        COMMAND ${CMAKE_COMMAND} -E echo "#include <stddef.h>"
            >> "${PSI_EMBED_HTML}"
        COMMAND ${CMAKE_COMMAND} -E echo "#include \"psi/embedded_data.h\""
            >> "${PSI_EMBED_HTML}"
        COMMAND ${CMAKE_COMMAND} -E echo "const struct psi_embedded_data psi_embedded_html_table[] = { { NULL, NULL, 0u, 0u } };"
            >> "${PSI_EMBED_HTML}"
        COMMENT "Stubbing psi SPA table (PSI_INCLUDE_SPA=OFF)"
        VERBATIM
    )
endif()

# Tie the generated blobs to the component build target so ninja
# orders the embed step correctly.
add_custom_target(psi_generate_embeds DEPENDS
    ${PSI_EMBED_LUA} ${PSI_EMBED_DOCS} ${PSI_EMBED_HTML})
add_dependencies(${COMPONENT_LIB} psi_generate_embeds)
