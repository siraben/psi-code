PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
INCLUDEDIR = $(PREFIX)/include
SHAREDIR = $(PREFIX)/share/psi

CC ?= cc
PKG_CONFIG ?= pkg-config

CFLAGS ?= -O2
CPPFLAGS ?=
LDFLAGS ?=

# STATIC=1 produces a statically linked binary. Each dependency's
# transitive link dependencies come through pkg-config --static; for a
# fully static ELF (no ld.so) the toolchain must also supply static
# libc — use nix pkgsStatic (musl-based) rather than a stock distro
# gcc, since glibc can't be fully statically linked in general.
STATIC ?= 0
ifeq ($(STATIC),1)
PKG_CONFIG_FLAGS = --static
LDFLAGS += -static
else
PKG_CONFIG_FLAGS =
endif

BASE_CFLAGS = -std=c89 -pedantic -Wall -Wextra -Werror

# Per-dependency CFLAGS/LIBS. Each is sourced from pkg-config by
# default; on platforms without pkg-config (or where a particular
# package is named differently — e.g. lua5.4 vs lua54 vs lua), set
# PSI_CFLAGS_<DEP>= and PSI_LIBS_<DEP>= in the environment to skip
# the pkg-config call. This is the S9fES-style escape hatch — the
# build never fails because pkg-config is missing, only because the
# user hasn't told us where to find a library.
pkg_cflags = $(if $(PSI_CFLAGS_$(1)),$(PSI_CFLAGS_$(1)),$(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --cflags $(2) 2>/dev/null))
pkg_libs   = $(if $(PSI_LIBS_$(1)),$(PSI_LIBS_$(1)),$(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --libs $(2) 2>/dev/null))

LOCAL_CPPFLAGS  = -Iinclude -DPSI_LUA_BOOT_FILE=\"$(LUA_BOOT_FILE)\"
LOCAL_CPPFLAGS += $(call pkg_cflags,LUA,lua5.4)
LOCAL_CPPFLAGS += $(call pkg_cflags,CJSON,libcjson)
LOCAL_CPPFLAGS += $(call pkg_cflags,EDIT,libedit)
LOCAL_CPPFLAGS += $(call pkg_cflags,CURL,libcurl)
LOCAL_CPPFLAGS += $(call pkg_cflags,ZLIB,zlib)
LOCAL_CPPFLAGS += $(call pkg_cflags,NCURSES,ncursesw ncurses)

LOCAL_LDFLAGS  = $(call pkg_libs,LUA,lua5.4)
LOCAL_LDFLAGS += $(call pkg_libs,CJSON,libcjson)
LOCAL_LDFLAGS += $(call pkg_libs,EDIT,libedit)
LOCAL_LDFLAGS += $(call pkg_libs,CURL,libcurl)
LOCAL_LDFLAGS += $(call pkg_libs,ZLIB,zlib)
LOCAL_LDFLAGS += $(call pkg_libs,NCURSES,ncursesw ncurses)
LOCAL_LDFLAGS += $(if $(PSI_LIBS_ARGTABLE),$(PSI_LIBS_ARGTABLE),-largtable3)
LOCAL_LDFLAGS += $(if $(PSI_LIBS_PTHREAD),$(PSI_LIBS_PTHREAD),-lpthread)

LUA_BOOT_FILE ?= $(abspath lua/boot.lua)

BUILD_DIR = build
TARGET = $(BUILD_DIR)/psi

# Every .lua file under lua/ gets compiled into the binary as a byte
# array. embed_lua (a host-side helper built from scripts/embed_lua.c)
# generates the C from the file list. README.md + docs/*.md are
# embedded similarly under a second table (psi_embedded_docs_table)
# so a portable static binary can self-describe without a source tree.
LUA_SOURCES = \
	lua/boot.lua \
	$(sort $(wildcard lua/psi/*.lua))
DOC_SOURCES = README.md $(sort $(wildcard docs/*.md))
EMBED_TOOL  = $(BUILD_DIR)/embed_lua
EMBED_OUT   = $(BUILD_DIR)/embedded_lua.c
EMBED_DOCS_OUT = $(BUILD_DIR)/embedded_docs.c

SOURCES = \
	src/main.c \
	src/core/abort.c \
	src/core/agent.c \
	src/core/common.c \
	src/core/anthropic.c \
	src/core/http_async.c \
	src/core/process.c \
	src/core/session.c \
	src/runtime/cli.c \
	src/runtime/print_mode.c \
	src/runtime/tui_mode.c \
	src/lua/vm.c

OBJECTS = \
	$(BUILD_DIR)/main.o \
	$(BUILD_DIR)/abort.o \
	$(BUILD_DIR)/agent.o \
	$(BUILD_DIR)/common.o \
	$(BUILD_DIR)/anthropic.o \
	$(BUILD_DIR)/http_async.o \
	$(BUILD_DIR)/process.o \
	$(BUILD_DIR)/session.o \
	$(BUILD_DIR)/cli.o \
	$(BUILD_DIR)/print_mode.o \
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

$(EMBED_TOOL): scripts/embed_lua.c | $(BUILD_DIR)
	$(CC) -O2 $(shell $(PKG_CONFIG) --cflags zlib) -o $@ $< $(shell $(PKG_CONFIG) --libs zlib)

$(EMBED_OUT): $(EMBED_TOOL) $(LUA_SOURCES)
	$(EMBED_TOOL) $(LUA_SOURCES) > $@

$(EMBED_DOCS_OUT): $(EMBED_TOOL) $(DOC_SOURCES)
	$(EMBED_TOOL) --table=psi_embedded_docs_table --raw-keys $(DOC_SOURCES) > $@

$(BUILD_DIR)/embedded_lua.o: $(EMBED_OUT) include/psi/embedded_lua.h
	$(CC) $(CPPFLAGS) -Iinclude $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/embedded_docs.o: $(EMBED_DOCS_OUT) include/psi/embedded_lua.h
	$(CC) $(CPPFLAGS) -Iinclude $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJECTS) | $(BUILD_DIR)
	$(CC) $(LDFLAGS) -o $@ $(OBJECTS) $(LOCAL_LDFLAGS)

$(BUILD_DIR)/main.o: src/main.c include/psi/common.h include/psi/runtime.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/abort.o: src/core/abort.c include/psi/abort.h include/psi/common.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/agent.o: src/core/agent.c include/psi/abort.h include/psi/agent.h include/psi/anthropic.h include/psi/common.h include/psi/session.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/common.o: src/core/common.c include/psi/common.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/anthropic.o: src/core/anthropic.c include/psi/abort.h include/psi/anthropic.h include/psi/common.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/http_async.o: src/core/http_async.c include/psi/abort.h include/psi/common.h include/psi/http_async.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/process.o: src/core/process.c include/psi/common.h include/psi/process.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/session.o: src/core/session.c include/psi/common.h include/psi/message.h include/psi/session.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/cli.o: src/runtime/cli.c include/psi/common.h include/psi/runtime.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/print_mode.o: src/runtime/print_mode.c include/psi/common.h include/psi/message.h include/psi/runtime.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/tui_mode.o: src/runtime/tui_mode.c include/psi/agent.h include/psi/common.h include/psi/message.h include/psi/runtime.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/vm.o: src/lua/vm.c include/psi/common.h include/psi/embedded_lua.h include/psi/host_ops.h include/psi/http_async.h include/psi/message.h include/psi/process.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

install: $(TARGET)
	mkdir -p $(DESTDIR)$(BINDIR) $(DESTDIR)$(INCLUDEDIR)/psi $(DESTDIR)$(SHAREDIR)/psi
	cp $(TARGET) $(DESTDIR)$(BINDIR)/psi
	cp include/psi/*.h $(DESTDIR)$(INCLUDEDIR)/psi/
	cp lua/boot.lua $(DESTDIR)$(SHAREDIR)/boot.lua
	cp lua/psi/*.lua $(DESTDIR)$(SHAREDIR)/psi/

clean:
	rm -rf $(BUILD_DIR)

# ---- static analysis ----
#
# `make analyze` runs cppcheck + gcc -fanalyzer. Both are installed in
# the dev shell; on bare systems install them or skip the target.

CPPCHECK ?= cppcheck
analyze-cppcheck:
	$(CPPCHECK) --enable=all --inconclusive --std=c89 \
		--suppressions-list=.cppcheck-suppressions \
		--error-exitcode=1 \
		-I include --quiet src/

analyze-gcc:
	$(MAKE) clean
	$(MAKE) CFLAGS="-O2 -fanalyzer"

analyze: analyze-cppcheck analyze-gcc

.PHONY: all clean install analyze analyze-cppcheck analyze-gcc
