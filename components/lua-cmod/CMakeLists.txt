# Lua 5.5 as an ESP-IDF component.
#
# We don't vendor the Lua source tree into the repo. The Nix flake
# fetches lua-5.5.0.tar.gz, unpacks it, and points LUA_SRC_DIR at
# the result before invoking idf.py build. If you're building outside
# Nix, set LUA_SRC_DIR to a directory containing lapi.c, lauxlib.c,
# etc. (the contents of lua-5.5.0/src/).

if(NOT DEFINED ENV{LUA_SRC_DIR})
    message(FATAL_ERROR
        "LUA_SRC_DIR not set. Pass the path to the Lua 5.5 src/ "
        "directory via the environment, e.g. "
        "LUA_SRC_DIR=$NIX_BUILD_TOP/lua-5.5.0/src.")
endif()
set(LUA_SRC "$ENV{LUA_SRC_DIR}")

# Lua's source list. Excludes lua.c (CLI) and luac.c (compiler).
file(GLOB LUA_SOURCES "${LUA_SRC}/l*.c")
list(FILTER LUA_SOURCES EXCLUDE REGEX "/lua\\.c$|/luac\\.c$|/onelua\\.c$")

idf_component_register(
    SRCS ${LUA_SOURCES}
    INCLUDE_DIRS "${LUA_SRC}"
    REQUIRES
)

# Lua 5.5 builds cleanly under C89 with these flags. The ESP-IDF
# default warning set includes -Wmissing-prototypes which Lua's
# private statics would trigger; allow it on these sources.
target_compile_options(${COMPONENT_LIB} PRIVATE
    -DLUA_USE_C89
    -Wno-missing-prototypes
    -Wno-string-plus-int
)
