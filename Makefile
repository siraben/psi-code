# psi build. Designed for GNU make 3.81+.

# ---- Install paths ----
PREFIX     ?= /usr/local
BINDIR      = $(PREFIX)/bin
INCLUDEDIR  = $(PREFIX)/include
SHAREDIR    = $(PREFIX)/share/psi
MANDIR     ?= $(PREFIX)/share/man
MAN1DIR     = $(MANDIR)/man1

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
CLANG_FORMAT    ?= clang-format
LUACHECK        ?= luacheck
SCAN_BUILD      ?= scan-build-py
SCAN_BUILD_CC   ?= gcc
SCAN_BUILD_ANALYZER ?= clang
STYLUA          ?= stylua

# ---- Feature gates ----
TUI           ?= 1
ANSI          ?= 1
COLOR         ?= 1
MCP           ?= 1
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
GIT_COMMIT   ?= $(shell git rev-parse --short HEAD 2>/dev/null || printf unknown)

# -Wno-long-long suppresses the C90-pedantic warning Lua forces
# via lua_Integer being long long.
STRICT_CFLAGS ?= -std=c89 -pedantic -Wall -Wextra -Werror -Wno-long-long
BASE_CFLAGS    = $(STRICT_CFLAGS)

# Auto-deps: gcc/clang/tcc emit .d files with these flags. On
# toolchains that can't (e.g. Plan 9 pcc), `make DEPFLAGS=` disables
# header-driven rebuild tracking; the build itself still works.
DEPFLAGS ?= -MMD -MP

# ---- Build outputs ----
BUILD_DIR      = build
TARGET         = $(BUILD_DIR)/psi
LUA_BOOT_FILE ?= $(abspath lua/boot.lua)
CA_BUNDLE_FILE ?= $(CURL_CA_BUNDLE)

SOURCES := $(sort $(shell find src -name '*.c' 2>/dev/null))
OBJECTS := $(SOURCES:%.c=$(BUILD_DIR)/%.o)
C_FORMAT_FILES := $(sort $(shell find include scripts src -type f \( -name '*.c' -o -name '*.h' \) 2>/dev/null))

LUA_SOURCES = lua/boot.lua $(sort $(shell find lua/psi -name '*.lua' 2>/dev/null))
DOC_SOURCES = README.md $(sort $(wildcard docs/*.md))
EMBED_TOOL  = $(BUILD_DIR)/embed
EMBED_LUA   = $(BUILD_DIR)/embedded_lua.c
EMBED_DOCS  = $(BUILD_DIR)/embedded_docs.c
EMBED_CA_FILE ?=
EMBED_CA_KEY ?= ca-bundle
EMBED_CA    = $(BUILD_DIR)/embedded_ca.c
GEN_OBJECTS = $(EMBED_LUA:.c=.o) $(EMBED_DOCS:.c=.o)
ifneq ($(EMBED_CA_FILE),)
GEN_OBJECTS += $(EMBED_CA:.c=.o)
EMBED_CA_CPPFLAGS = -DPSI_HAVE_EMBEDDED_CA=1
endif
CA_BUNDLE_CPPFLAGS = $(if $(CA_BUNDLE_FILE),-DPSI_CA_BUNDLE_FILE=\"$(CA_BUNDLE_FILE)\")
DEPS       := $(OBJECTS:.o=.d) $(GEN_OBJECTS:.o=.d)

# ---- Dependencies via pkg-config ----
#
# Set PSI_CFLAGS_<DEP>= / PSI_LIBS_<DEP>= in the environment to skip
# pkg-config for a particular package — useful on hosts where the
# package is named differently (lua5.5 vs lua55 vs lua) or where
# pkg-config isn't available at all.
ifeq ($(STATIC),1)
PKG_CONFIG_FLAGS = --static
LDFLAGS         += -static
else
PKG_CONFIG_FLAGS =
endif

pkg_cflags = $(if $(PSI_CFLAGS_$(1)),$(PSI_CFLAGS_$(1)),$(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --cflags $(2) 2>/dev/null))
pkg_libs   = $(if $(PSI_LIBS_$(1)),$(PSI_LIBS_$(1)),$(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --libs $(2) 2>/dev/null))

# Each PKG_DEPS entry is "<override-prefix>:<pkg-config-name>".
dep_cflags = $(call pkg_cflags,$(firstword $(subst :, ,$(1))),$(lastword $(subst :, ,$(1))))
dep_libs   = $(call pkg_libs,$(firstword $(subst :, ,$(1))),$(lastword $(subst :, ,$(1))))

LUA_PKG_CONFIG ?= lua5.5
PKG_DEPS  = LUA:$(LUA_PKG_CONFIG) CJSON:libcjson CURL:libcurl ZLIB:zlib
PKG_DEPS += $(if $(filter 1,$(REPL_EDITLINE)),EDIT:libedit)

LOCAL_CPPFLAGS  = -Iinclude -D_DEFAULT_SOURCE -D_XOPEN_SOURCE=600 \
                  -DPSI_LUA_BOOT_FILE=\"$(LUA_BOOT_FILE)\" \
                  -DPSI_GIT_COMMIT=\"$(GIT_COMMIT)\" \
                  -DPSI_ENABLE_TUI=$(TUI) \
                  -DPSI_ENABLE_ANSI=$(ANSI) \
                  -DPSI_ENABLE_COLOR=$(COLOR) \
                  -DPSI_ENABLE_MCP=$(MCP) \
                  -DPSI_ENABLE_REPL_EDITLINE=$(REPL_EDITLINE)
LOCAL_CPPFLAGS += $(EMBED_CA_CPPFLAGS)
LOCAL_CPPFLAGS += $(CA_BUNDLE_CPPFLAGS)
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

# Cross builds: HOST_* vars must point at the build host's zlib so
# the embed helper doesn't link against the target arch's libs.
HOST_CFLAGS_ZLIB ?= $(shell $(HOST_PKG_CONFIG) --cflags zlib)
HOST_LIBS_ZLIB   ?= $(shell $(HOST_PKG_CONFIG) --libs zlib)

# ---- Default target ----
.DEFAULT_GOAL := all
all: $(TARGET)

# ---- Pattern rules ----
$(OBJECTS): $(BUILD_DIR)/%.o: %.c
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

# Generated blobs only need psi/embedded_data.h.
$(GEN_OBJECTS): $(BUILD_DIR)/%.o: $(BUILD_DIR)/%.c
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) -Iinclude $(BASE_CFLAGS) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

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

$(EMBED_CA): $(EMBED_TOOL) $(EMBED_CA_FILE)
	$(EMBED_TOOL) --table=psi_embedded_ca_table --key=$(EMBED_CA_KEY) $(EMBED_CA_FILE) > $@

# ---- Link ----
.PHONY: check-curl-ca
check-curl-ca:
	@if printf '%s\n' "$(CURL_SSL_BACKENDS)" | grep -qi 'mbedTLS' && [ -z "$(CA_BUNDLE_FILE)" ] && [ -z "$(EMBED_CA_FILE)" ]; then \
		echo "error: libcurl is built with mbedTLS but no CA bundle was configured"; \
		echo "       set CA_BUNDLE_FILE, EMBED_CA_FILE, or rebuild libcurl with curl-config --ca"; \
		exit 1; \
	fi

# Order-only so check-curl-ca's phony status doesn't relink every build.
$(TARGET): $(OBJECTS) $(GEN_OBJECTS) | check-curl-ca $(BUILD_DIR)
	$(CC) $(LDFLAGS) $(RPATH_LDFLAGS) -o $@ $(OBJECTS) $(GEN_OBJECTS) $(LOCAL_LDFLAGS)

# ---- Install / clean ----
install: $(TARGET)
	$(INSTALL_DIR) $(DESTDIR)$(BINDIR) $(DESTDIR)$(INCLUDEDIR)/psi $(DESTDIR)$(SHAREDIR)/psi $(DESTDIR)$(MAN1DIR)
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/psi
	$(INSTALL_DATA) include/psi/*.h $(DESTDIR)$(INCLUDEDIR)/psi/
	$(INSTALL_DATA) lua/boot.lua $(DESTDIR)$(SHAREDIR)/boot.lua
	cd lua && find psi -type d -exec $(INSTALL_DIR) '$(DESTDIR)$(SHAREDIR)'/{} \;
	cd lua && find psi -type f -name '*.lua' -exec $(INSTALL_DATA) {} '$(DESTDIR)$(SHAREDIR)'/{} \;
	$(INSTALL_DATA) psi.1 $(DESTDIR)$(MAN1DIR)/psi.1

clean:
	rm -rf $(BUILD_DIR)

# ---- Lint / static analysis ----
lint-lua:
	$(STYLUA) --check lua
	$(LUACHECK) lua

format-lua:
	$(STYLUA) lua

format-c:
	$(CLANG_FORMAT) -i $(C_FORMAT_FILES)

check-format-c:
	$(CLANG_FORMAT) --dry-run --Werror $(C_FORMAT_FILES)

format: format-lua format-c

analyze-cppcheck:
	$(CPPCHECK) --enable=all --inconclusive --std=c89 \
		--suppressions-list=.cppcheck-suppressions \
		--error-exitcode=1 \
		-I include --quiet src/

analyze-gcc:
	$(MAKE) clean
	$(MAKE) CFLAGS="-O2 -fanalyzer"

analyze-scan-build:
	rm -rf $(BUILD_DIR) $(BUILD_DIR)-scan-build
	$(SCAN_BUILD) --status-bugs \
		--intercept-first \
		--use-cc=$(SCAN_BUILD_CC) \
		--use-analyzer=$(SCAN_BUILD_ANALYZER) \
		--output=$(BUILD_DIR)-scan-build \
		$(MAKE) CC=$(SCAN_BUILD_CC) HOST_CC=$(SCAN_BUILD_CC)

analyze-infer: $(OBJECTS)

analyze: analyze-cppcheck analyze-gcc

lint-c: analyze
lint:   lint-lua lint-c

check-build-configs:
	sh tests/build_configs.sh

# Regenerate the @generated:* regions in README.md / docs/*.md and emit psi.1.
# Source of truth: lua/psi/{slash_commands,keybindings,api_registry,tools/*}.lua,
# src/runtime/cli.c (argtable3 calls), src/lua/vm.c (PSI_REG calls).
docs: $(TARGET)
	./$(TARGET) --eval 'dofile("scripts/gen-docs.lua")'

# Drift check: regenerate, then assert nothing changed under version control.
# Runs in CI alongside analyze.
check-docs: $(TARGET)
	./$(TARGET) --eval 'dofile("scripts/gen-docs.lua")'
	@if ! git diff --quiet -- README.md docs/ psi.1; then \
		echo ""; \
		echo "ERROR: generated docs are out of sync with their Lua/C sources."; \
		echo "Run 'make docs' and commit the result."; \
		echo ""; \
		git --no-pager diff --stat -- README.md docs/ psi.1; \
		exit 1; \
	fi

.PHONY: all clean install \
        lint lint-lua lint-c format format-lua format-c check-format-c \
        analyze analyze-cppcheck analyze-gcc analyze-scan-build analyze-infer \
        check-build-configs docs check-docs
