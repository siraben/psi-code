PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
INCLUDEDIR = $(PREFIX)/include
SHAREDIR = $(PREFIX)/share/psi

CC ?= cc
HOST_CC ?= $(CC)
PKG_CONFIG ?= pkg-config
INSTALL ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 755
INSTALL_DATA ?= $(INSTALL) -m 644
INSTALL_DIR ?= $(INSTALL) -d
# embed_lua links zlib at host build time. On a native build it shares
# pkg-config with the target; on cross builds the caller must override
# HOST_CFLAGS_ZLIB / HOST_LIBS_ZLIB (or HOST_PKG_CONFIG) so the host
# helper doesn't accidentally link against the target's zlib.
HOST_PKG_CONFIG ?= $(PKG_CONFIG)
HOST_CFLAGS_ZLIB ?= $(shell $(HOST_PKG_CONFIG) --cflags zlib)
HOST_LIBS_ZLIB ?= $(shell $(HOST_PKG_CONFIG) --libs zlib)
comma := ,

CFLAGS ?= -O2
CPPFLAGS ?=
LDFLAGS ?=
RPATH_LDFLAGS ?=

# STATIC=1 produces a statically linked binary. Each dependency's
# transitive link dependencies come through pkg-config --static; for a
# fully static ELF (no ld.so) the toolchain must also supply static
# libc — use nix pkgsStatic (musl-based) rather than a stock distro
# gcc, since glibc can't be fully statically linked in general.
STATIC ?= 0
TUI ?= 1
ANSI ?= 1
COLOR ?= 1
REPL_EDITLINE ?= 1
ifeq ($(ANSI),0)
# The Lua TUI backend is ANSI-terminal based. A no-ANSI build should keep
# --tui unavailable instead of compiling a TUI that still emits escapes.
TUI := 0
endif
ifeq ($(STATIC),1)
PKG_CONFIG_FLAGS = --static
LDFLAGS += -static
else
PKG_CONFIG_FLAGS =
endif

# -Wno-long-long: Lua 5.4 mandates `long long` for lua_Integer (see
# luaconf.h), which trips ISO C90 -pedantic. Suppress the warning
# rather than dropping -std=c89 so our own code stays C89-clean.
STRICT_CFLAGS ?= -std=c89 -pedantic -Wall -Wextra -Werror -Wno-long-long
BASE_CFLAGS = $(STRICT_CFLAGS)

# Per-dependency CFLAGS/LIBS. Each is sourced from pkg-config by
# default; on platforms without pkg-config (or where a particular
# package is named differently — e.g. lua5.4 vs lua54 vs lua), set
# PSI_CFLAGS_<DEP>= and PSI_LIBS_<DEP>= in the environment to skip
# the pkg-config call. This is the S9fES-style escape hatch — the
# build never fails because pkg-config is missing, only because the
# user hasn't told us where to find a library.
pkg_cflags = $(if $(PSI_CFLAGS_$(1)),$(PSI_CFLAGS_$(1)),$(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --cflags $(2) 2>/dev/null))
pkg_libs   = $(if $(PSI_LIBS_$(1)),$(PSI_LIBS_$(1)),$(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --libs $(2) 2>/dev/null))

LOCAL_CPPFLAGS  = -Iinclude -D_DEFAULT_SOURCE -D_XOPEN_SOURCE=600
LOCAL_CPPFLAGS += -DPSI_LUA_BOOT_FILE=\"$(LUA_BOOT_FILE)\"
LOCAL_CPPFLAGS += -DPSI_ENABLE_TUI=$(TUI)
LOCAL_CPPFLAGS += -DPSI_ENABLE_ANSI=$(ANSI)
LOCAL_CPPFLAGS += -DPSI_ENABLE_COLOR=$(COLOR)
LOCAL_CPPFLAGS += -DPSI_ENABLE_REPL_EDITLINE=$(REPL_EDITLINE)
LOCAL_CPPFLAGS += $(call pkg_cflags,LUA,lua5.4)
LOCAL_CPPFLAGS += $(call pkg_cflags,CJSON,libcjson)
ifeq ($(REPL_EDITLINE),1)
LOCAL_CPPFLAGS += $(call pkg_cflags,EDIT,libedit)
endif
LOCAL_CPPFLAGS += $(call pkg_cflags,CURL,libcurl)
LOCAL_CPPFLAGS += $(call pkg_cflags,ZLIB,zlib)
LOCAL_CPPFLAGS += $(call pkg_cflags,ARGTABLE,argtable3)

LOCAL_LDFLAGS  = $(call pkg_libs,LUA,lua5.4)
LOCAL_LDFLAGS += $(call pkg_libs,CJSON,libcjson)
ifeq ($(REPL_EDITLINE),1)
LOCAL_LDFLAGS += $(call pkg_libs,EDIT,libedit)
endif
LOCAL_LDFLAGS += $(call pkg_libs,CURL,libcurl)
LOCAL_LDFLAGS += $(call pkg_libs,ZLIB,zlib)
LOCAL_LDFLAGS += $(if $(PSI_LIBS_ARGTABLE),$(PSI_LIBS_ARGTABLE),$(or $(call pkg_libs,ARGTABLE,argtable3),-largtable3))
LOCAL_LDFLAGS += $(if $(PSI_LIBS_PTHREAD),$(PSI_LIBS_PTHREAD),-lpthread)
LOCAL_RPATH_LDFLAGS = $(patsubst -L%,-Wl$(comma)-rpath$(comma)%,$(filter -L%,$(LOCAL_LDFLAGS)))
CURL_SSL_BACKENDS = $(shell curl-config --ssl-backends 2>/dev/null)
CURL_CA_BUNDLE = $(shell curl-config --ca 2>/dev/null)

LUA_BOOT_FILE ?= $(abspath lua/boot.lua)

BUILD_DIR = build
TARGET = $(BUILD_DIR)/psi

# Every .lua file under lua/ gets compiled into the binary as a byte
# array. The embed helper (a host-side tool built from scripts/embed.c)
# generates the C from the file list. README.md + docs/*.md are
# embedded similarly under a second table (psi_embedded_docs_table)
# so a portable static binary can self-describe without a source tree.
LUA_SOURCES = \
	lua/boot.lua \
	$(sort $(shell find lua/psi -type f -name '*.lua' 2>/dev/null))
DOC_SOURCES = README.md $(sort $(wildcard docs/*.md))
EMBED_TOOL  = $(BUILD_DIR)/embed
EMBED_OUT   = $(BUILD_DIR)/embedded_lua.c
EMBED_DOCS_OUT = $(BUILD_DIR)/embedded_docs.c

SOURCES = \
	src/main.c \
	src/core/abort.c \
	src/core/agent_runtime.c \
	src/core/common.c \
	src/core/http_buffered.c \
	src/core/http_async.c \
	src/core/process.c \
	src/core/session.c \
	src/runtime/cli.c \
	src/runtime/cli_mode.c \
	src/runtime/tui_mode.c \
	src/lua/vm.c

OBJECTS = \
	$(BUILD_DIR)/main.o \
	$(BUILD_DIR)/abort.o \
	$(BUILD_DIR)/agent_runtime.o \
	$(BUILD_DIR)/common.o \
	$(BUILD_DIR)/http_buffered.o \
	$(BUILD_DIR)/http_async.o \
	$(BUILD_DIR)/process.o \
	$(BUILD_DIR)/session.o \
	$(BUILD_DIR)/cli.o \
	$(BUILD_DIR)/cli_mode.o \
	$(BUILD_DIR)/tui_mode.o \
	$(BUILD_DIR)/vm.o \
	$(BUILD_DIR)/embedded_lua.o \
	$(BUILD_DIR)/embedded_docs.o

all: $(TARGET)

# Parallel-build by default: use all CPUs unless the caller passed -j
# explicitly or overrode MAKEFLAGS. `nproc` is Linux-specific; on other
# platforms fall back to 4.
JOBS := $(shell nproc 2>/dev/null || echo 4)
ifeq (,$(filter -j%,$(MAKEFLAGS)))
MAKEFLAGS += -j$(JOBS)
endif

# All object builds share the output directory; declare it as an
# order-only prereq so `make -jN` doesn't race on mkdir.
$(OBJECTS): | $(BUILD_DIR)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(EMBED_TOOL): scripts/embed.c | $(BUILD_DIR)
	$(HOST_CC) -O2 $(HOST_CFLAGS_ZLIB) -o $@ $< $(HOST_LIBS_ZLIB)

$(EMBED_OUT): $(EMBED_TOOL) $(LUA_SOURCES)
	$(EMBED_TOOL) $(LUA_SOURCES) > $@

$(EMBED_DOCS_OUT): $(EMBED_TOOL) $(DOC_SOURCES)
	$(EMBED_TOOL) --table=psi_embedded_docs_table --raw-keys $(DOC_SOURCES) > $@

$(BUILD_DIR)/embedded_lua.o: $(EMBED_OUT) include/psi/embedded_lua.h
	$(CC) $(CPPFLAGS) -Iinclude $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/embedded_docs.o: $(EMBED_DOCS_OUT) include/psi/embedded_lua.h
	$(CC) $(CPPFLAGS) -Iinclude $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

.PHONY: check-curl-ca
check-curl-ca:
	@if printf '%s\n' "$(CURL_SSL_BACKENDS)" | grep -qi 'mbedTLS' && [ -z "$(CURL_CA_BUNDLE)" ]; then \
		echo "error: libcurl is built with mbedTLS but has no default CA bundle"; \
		echo "       enter a fresh nix develop shell so curl picks up the flake cacert build"; \
		echo "       or rebuild/provide libcurl with curl-config --ca set"; \
		exit 1; \
	fi

$(TARGET): check-curl-ca $(OBJECTS) | $(BUILD_DIR)
	$(CC) $(LDFLAGS) $(RPATH_LDFLAGS) -o $@ $(OBJECTS) $(LOCAL_LDFLAGS)

$(BUILD_DIR)/main.o: src/main.c include/psi/common.h include/psi/runtime.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/abort.o: src/core/abort.c include/psi/abort.h include/psi/common.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/agent_runtime.o: src/core/agent_runtime.c include/psi/abort.h include/psi/agent_runtime.h include/psi/http_buffered.h include/psi/common.h include/psi/session.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/common.o: src/core/common.c include/psi/common.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/http_buffered.o: src/core/http_buffered.c include/psi/abort.h include/psi/http_buffered.h include/psi/common.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/http_async.o: src/core/http_async.c include/psi/abort.h include/psi/common.h include/psi/http_async.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/process.o: src/core/process.c include/psi/common.h include/psi/process.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/session.o: src/core/session.c include/psi/common.h include/psi/message.h include/psi/session.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/cli.o: src/runtime/cli.c include/psi/common.h include/psi/runtime.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/cli_mode.o: src/runtime/cli_mode.c include/psi/common.h include/psi/message.h include/psi/runtime.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/tui_mode.o: src/runtime/tui_mode.c include/psi/agent_runtime.h include/psi/common.h include/psi/message.h include/psi/runtime.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/vm.o: src/lua/vm.c include/psi/common.h include/psi/embedded_lua.h include/psi/host_ops.h include/psi/http_async.h include/psi/message.h include/psi/process.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

install: $(TARGET)
	$(INSTALL_DIR) $(DESTDIR)$(BINDIR) $(DESTDIR)$(INCLUDEDIR)/psi $(DESTDIR)$(SHAREDIR)/psi
	$(INSTALL_PROGRAM) $(TARGET) $(DESTDIR)$(BINDIR)/psi
	$(INSTALL_DATA) include/psi/*.h $(DESTDIR)$(INCLUDEDIR)/psi/
	$(INSTALL_DATA) lua/boot.lua $(DESTDIR)$(SHAREDIR)/boot.lua
	cd lua && find psi -type d -exec $(INSTALL_DIR) '$(DESTDIR)$(SHAREDIR)'/{} \;
	cd lua && find psi -type f -name '*.lua' -exec $(INSTALL_DATA) {} '$(DESTDIR)$(SHAREDIR)'/{} \;

clean:
	rm -rf $(BUILD_DIR)

# ---- static analysis ----
#
# `make analyze` runs cppcheck + gcc -fanalyzer. Both are installed in
# the dev shell; on bare systems install them or skip the target.

CPPCHECK ?= cppcheck
LUACHECK ?= luacheck
STYLUA ?= stylua

lint-lua:
	$(STYLUA) --check lua
	$(LUACHECK) lua

format-lua:
	$(STYLUA) lua

lint-c: analyze

lint: lint-lua lint-c

analyze-cppcheck:
	$(CPPCHECK) --enable=all --inconclusive --std=c89 \
		--suppressions-list=.cppcheck-suppressions \
		--error-exitcode=1 \
		-I include --quiet src/

analyze-gcc:
	$(MAKE) clean
	$(MAKE) CFLAGS="-O2 -fanalyzer"

analyze: analyze-cppcheck analyze-gcc

check-build-configs:
	sh tests/build_configs.sh

.PHONY: all clean install lint lint-lua lint-c format-lua analyze analyze-cppcheck analyze-gcc check-build-configs
