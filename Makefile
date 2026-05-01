# psi build — minimal, portable, parallel-safe.
#
# Configuration knobs at the top; machinery below. Designed for GNU
# make 3.81+ since pattern rules, $(call), $(foreach), and -include
# are used pervasively.

# ---- Install paths ----
PREFIX     ?= /usr/local
BINDIR      = $(PREFIX)/bin
INCLUDEDIR  = $(PREFIX)/include
SHAREDIR    = $(PREFIX)/share/psi

# ---- Toolchain ----
CC              ?= cc
HOST_CC         ?= $(CC)
PKG_CONFIG      ?= pkg-config
HOST_PKG_CONFIG ?= $(PKG_CONFIG)
INSTALL         ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 755
INSTALL_DATA    ?= $(INSTALL) -m 644
INSTALL_DIR     ?= $(INSTALL) -d
CPPCHECK        ?= cppcheck
LUACHECK        ?= luacheck
STYLUA          ?= stylua

# ---- Feature gates ----
# Each maps to a -DPSI_ENABLE_<NAME>=<0|1> compile flag and (where
# applicable) selects which optional dependencies the link picks up.
TUI           ?= 1
ANSI          ?= 1
COLOR         ?= 1
REPL_EDITLINE ?= 1
STATIC        ?= 0

# Lua TUI is ANSI-terminal-only; ANSI=0 implies TUI=0.
ifeq ($(ANSI),0)
TUI := 0
endif

# ---- User-facing flags ----
CFLAGS        ?= -O2
CPPFLAGS      ?=
LDFLAGS       ?=
RPATH_LDFLAGS ?=

# Stays at -std=c89 -pedantic -Werror so portable C89 hosts (Plan 9
# APE, AmigaOS, Haiku gcc-2.95, …) build without surprises.
# -Wno-long-long accommodates Lua 5.4's lua_Integer being long long.
STRICT_CFLAGS ?= -std=c89 -pedantic -Wall -Wextra -Werror -Wno-long-long
BASE_CFLAGS    = $(STRICT_CFLAGS)

# ---- Build outputs ----
BUILD_DIR      = build
TARGET         = $(BUILD_DIR)/psi
LUA_BOOT_FILE ?= $(abspath lua/boot.lua)

# Source discovery: every .c under src/ is part of the binary. The
# build mirror under $(BUILD_DIR) preserves the src/ layout so two
# files with the same basename (none today, but cheap insurance)
# never collide.
SOURCES := $(sort $(shell find src -name '*.c' 2>/dev/null))
OBJECTS := $(SOURCES:%.c=$(BUILD_DIR)/%.o)

# Embedded blobs: lua/ sources go into psi_embedded_lua_table;
# README.md + docs/*.md go into psi_embedded_docs_table.
LUA_SOURCES = lua/boot.lua $(sort $(shell find lua/psi -name '*.lua' 2>/dev/null))
DOC_SOURCES = README.md $(sort $(wildcard docs/*.md))
EMBED_TOOL  = $(BUILD_DIR)/embed
EMBED_LUA   = $(BUILD_DIR)/embedded_lua.c
EMBED_DOCS  = $(BUILD_DIR)/embedded_docs.c
GEN_OBJECTS = $(EMBED_LUA:.c=.o) $(EMBED_DOCS:.c=.o)

# Auto-generated header dependencies (-MMD -MP). One .d per .o.
DEPS := $(OBJECTS:.o=.d) $(GEN_OBJECTS:.o=.d)

# ---- Dependencies via pkg-config (with environment override) ----
#
# Each library is sourced from pkg-config by default; on platforms
# without pkg-config (or where a package is named differently — e.g.
# lua5.4 vs lua54 vs lua), set PSI_CFLAGS_<DEP>= and PSI_LIBS_<DEP>=
# in the environment to skip the pkg-config call. The build never
# fails because pkg-config is missing, only because the user hasn't
# told us where to find a library.
ifeq ($(STATIC),1)
PKG_CONFIG_FLAGS = --static
LDFLAGS         += -static
else
PKG_CONFIG_FLAGS =
endif

# Resolve --cflags / --libs for a single package, with PSI_CFLAGS_X /
# PSI_LIBS_X taking precedence over pkg-config.
pkg_cflags = $(if $(PSI_CFLAGS_$(1)),$(PSI_CFLAGS_$(1)),$(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --cflags $(2) 2>/dev/null))
pkg_libs   = $(if $(PSI_LIBS_$(1)),$(PSI_LIBS_$(1)),$(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --libs $(2) 2>/dev/null))

# A "VAR:pkgname" entry (e.g. LUA:lua5.4) names the override-var
# prefix and the pkg-config package. firstword/lastword split the
# colon-separated pair without an intermediate variable.
dep_cflags = $(call pkg_cflags,$(firstword $(subst :, ,$(1))),$(lastword $(subst :, ,$(1))))
dep_libs   = $(call pkg_libs,$(firstword $(subst :, ,$(1))),$(lastword $(subst :, ,$(1))))

# Always-on dependencies; feature-gated ones append below.
PKG_DEPS  = LUA:lua5.4 CJSON:libcjson CURL:libcurl ZLIB:zlib
PKG_DEPS += $(if $(filter 1,$(REPL_EDITLINE)),EDIT:libedit)

LOCAL_CPPFLAGS  = -Iinclude -D_DEFAULT_SOURCE -D_XOPEN_SOURCE=600 \
                  -DPSI_LUA_BOOT_FILE=\"$(LUA_BOOT_FILE)\" \
                  -DPSI_ENABLE_TUI=$(TUI) \
                  -DPSI_ENABLE_ANSI=$(ANSI) \
                  -DPSI_ENABLE_COLOR=$(COLOR) \
                  -DPSI_ENABLE_REPL_EDITLINE=$(REPL_EDITLINE)
LOCAL_CPPFLAGS += $(foreach d,$(PKG_DEPS),$(call dep_cflags,$(d)))
LOCAL_CPPFLAGS += $(call pkg_cflags,ARGTABLE,argtable3)

LOCAL_LDFLAGS  = $(foreach d,$(PKG_DEPS),$(call dep_libs,$(d)))
# argtable3 isn't always packaged with pkg-config; fall back to -largtable3.
LOCAL_LDFLAGS += $(if $(PSI_LIBS_ARGTABLE),$(PSI_LIBS_ARGTABLE),$(or $(call pkg_libs,ARGTABLE,argtable3),-largtable3))
LOCAL_LDFLAGS += $(if $(PSI_LIBS_PTHREAD),$(PSI_LIBS_PTHREAD),-lpthread)

comma := ,
LOCAL_RPATH_LDFLAGS = $(patsubst -L%,-Wl$(comma)-rpath$(comma)%,$(filter -L%,$(LOCAL_LDFLAGS)))
CURL_SSL_BACKENDS   = $(shell curl-config --ssl-backends 2>/dev/null)
CURL_CA_BUNDLE      = $(shell curl-config --ca 2>/dev/null)

# Host-side embed helper links zlib at host-build time. On native
# builds it shares pkg-config with the target; cross builds set
# HOST_CFLAGS_ZLIB / HOST_LIBS_ZLIB so the host helper doesn't link
# against the target's zlib.
HOST_CFLAGS_ZLIB ?= $(shell $(HOST_PKG_CONFIG) --cflags zlib)
HOST_LIBS_ZLIB   ?= $(shell $(HOST_PKG_CONFIG) --libs zlib)

# Parallel-build by default unless the caller passed -j explicitly.
JOBS := $(shell nproc 2>/dev/null || echo 4)
ifeq (,$(filter -j%,$(MAKEFLAGS)))
MAKEFLAGS += -j$(JOBS)
endif

# ---- Default target ----
.DEFAULT_GOAL := all
all: $(TARGET)

# ---- Pattern rules ----
#
# Static pattern rules bind the recipe to a specific target list, so
# the rule only matches the intended .c → .o translations and never
# accidentally fires for an unrelated path. -MMD -MP emits .d sidecar
# files that record the headers each translation unit pulled in, so
# a header edit triggers a rebuild without hand-maintained dependency
# lists; the .d files are loaded back via -include below.
$(OBJECTS): $(BUILD_DIR)/%.o: %.c
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@

# Generated blobs (embedded_lua.c, embedded_docs.c) compile with a
# leaner include set — they only reference psi/embedded_lua.h.
$(GEN_OBJECTS): $(BUILD_DIR)/%.o: $(BUILD_DIR)/%.c
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) -Iinclude $(BASE_CFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@

# Pull in auto-generated header deps. `-include` is silent when the
# files don't exist (clean tree, first build).
-include $(DEPS)

# ---- Embed helper ----
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(EMBED_TOOL): scripts/embed.c | $(BUILD_DIR)
	$(HOST_CC) -O2 $(HOST_CFLAGS_ZLIB) -o $@ $< $(HOST_LIBS_ZLIB)

$(EMBED_LUA): $(EMBED_TOOL) $(LUA_SOURCES)
	$(EMBED_TOOL) $(LUA_SOURCES) > $@

$(EMBED_DOCS): $(EMBED_TOOL) $(DOC_SOURCES)
	$(EMBED_TOOL) --table=psi_embedded_docs_table --raw-keys $(DOC_SOURCES) > $@

# ---- Link ----
.PHONY: check-curl-ca
check-curl-ca:
	@if printf '%s\n' "$(CURL_SSL_BACKENDS)" | grep -qi 'mbedTLS' && [ -z "$(CURL_CA_BUNDLE)" ]; then \
		echo "error: libcurl is built with mbedTLS but has no default CA bundle"; \
		echo "       enter a fresh nix develop shell so curl picks up the flake cacert build"; \
		echo "       or rebuild/provide libcurl with curl-config --ca set"; \
		exit 1; \
	fi

# `check-curl-ca` is order-only so its phony status never marks
# $(TARGET) out-of-date; it still runs once per `make` invocation
# and aborts before linking if libcurl can't reach a CA bundle.
$(TARGET): $(OBJECTS) $(GEN_OBJECTS) | check-curl-ca $(BUILD_DIR)
	$(CC) $(LDFLAGS) $(RPATH_LDFLAGS) -o $@ $(OBJECTS) $(GEN_OBJECTS) $(LOCAL_LDFLAGS)

# ---- Install / clean ----
install: $(TARGET)
	$(INSTALL_DIR) $(DESTDIR)$(BINDIR) $(DESTDIR)$(INCLUDEDIR)/psi $(DESTDIR)$(SHAREDIR)/psi
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/psi
	$(INSTALL_DATA) include/psi/*.h $(DESTDIR)$(INCLUDEDIR)/psi/
	$(INSTALL_DATA) lua/boot.lua $(DESTDIR)$(SHAREDIR)/boot.lua
	cd lua && find psi -type d -exec $(INSTALL_DIR) '$(DESTDIR)$(SHAREDIR)'/{} \;
	cd lua && find psi -type f -name '*.lua' -exec $(INSTALL_DATA) {} '$(DESTDIR)$(SHAREDIR)'/{} \;

clean:
	rm -rf $(BUILD_DIR)

# ---- Lint / static analysis ----
#
# `make lint` runs the full battery (stylua, luacheck, cppcheck, gcc
# -fanalyzer). Each tool ships in the dev shell; on bare systems
# install them or invoke individual sub-targets.

lint-lua:
	$(STYLUA) --check lua
	$(LUACHECK) lua

format-lua:
	$(STYLUA) lua

analyze-cppcheck:
	$(CPPCHECK) --enable=all --inconclusive --std=c89 \
		--suppressions-list=.cppcheck-suppressions \
		--error-exitcode=1 \
		-I include --quiet src/

analyze-gcc:
	$(MAKE) clean
	$(MAKE) CFLAGS="-O2 -fanalyzer"

analyze: analyze-cppcheck analyze-gcc

lint-c: analyze
lint:   lint-lua lint-c

check-build-configs:
	sh tests/build_configs.sh

.PHONY: all clean install \
        lint lint-lua lint-c format-lua \
        analyze analyze-cppcheck analyze-gcc \
        check-build-configs
