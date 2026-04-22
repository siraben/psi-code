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
LOCAL_CPPFLAGS = -Iinclude -DPSI_LUA_BOOT_FILE=\"$(LUA_BOOT_FILE)\" $(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --cflags lua5.4 libcjson)
LOCAL_CPPFLAGS += $(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --cflags libedit)
LOCAL_CPPFLAGS += $(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --cflags libcurl)
LOCAL_CPPFLAGS += $(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --cflags ncursesw 2>/dev/null || $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --cflags ncurses 2>/dev/null)
LOCAL_LDFLAGS = $(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --libs lua5.4 libcjson libedit libcurl) $(shell $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --libs ncursesw 2>/dev/null || $(PKG_CONFIG) $(PKG_CONFIG_FLAGS) --libs ncurses 2>/dev/null) -largtable3 -lpthread

LUA_BOOT_FILE ?= $(abspath lua/boot.lua)

BUILD_DIR = build
TARGET = $(BUILD_DIR)/psi

SOURCES = \
	src/main.c \
	src/core/abort.c \
	src/core/agent.c \
	src/core/common.c \
	src/core/anthropic.c \
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
	$(BUILD_DIR)/process.o \
	$(BUILD_DIR)/session.o \
	$(BUILD_DIR)/cli.o \
	$(BUILD_DIR)/print_mode.o \
	$(BUILD_DIR)/tui_mode.o \
	$(BUILD_DIR)/vm.o

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): $(BUILD_DIR) $(OBJECTS)
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

$(BUILD_DIR)/vm.o: src/lua/vm.c include/psi/common.h include/psi/host_ops.h include/psi/message.h include/psi/process.h include/psi/session.h include/psi/vm.h
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
