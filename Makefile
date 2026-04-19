PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
INCLUDEDIR = $(PREFIX)/include
SHAREDIR = $(PREFIX)/share/psi

CC ?= cc
PKG_CONFIG ?= pkg-config

CFLAGS ?= -O2
CPPFLAGS ?=
LDFLAGS ?=

BASE_CFLAGS = -std=c89 -pedantic -Wall -Wextra -Werror
LOCAL_CPPFLAGS = -Iinclude -DPSI_SCHEME_BOOT_FILE=\"$(SCHEME_BOOT_FILE)\" $(shell $(PKG_CONFIG) --cflags chibi-scheme libcjson)
LOCAL_CPPFLAGS += $(shell $(PKG_CONFIG) --cflags libedit)
LOCAL_CPPFLAGS += $(shell $(PKG_CONFIG) --cflags libcurl)
LOCAL_LDFLAGS = $(shell $(PKG_CONFIG) --libs chibi-scheme libcjson libedit libcurl) -largtable3

SCHEME_BOOT_FILE ?= $(abspath scheme/boot.scm)

BUILD_DIR = build
TARGET = $(BUILD_DIR)/psi

SOURCES = \
	src/main.c \
	src/core/agent.c \
	src/core/common.c \
	src/core/anthropic.c \
	src/core/host_ops.c \
	src/core/message.c \
	src/core/process.c \
	src/core/prompt.c \
	src/core/tool.c \
	src/core/session.c \
	src/runtime/cli.c \
	src/runtime/print_mode.c \
	src/scheme/vm.c

OBJECTS = \
	$(BUILD_DIR)/main.o \
	$(BUILD_DIR)/agent.o \
	$(BUILD_DIR)/common.o \
	$(BUILD_DIR)/anthropic.o \
	$(BUILD_DIR)/host_ops.o \
	$(BUILD_DIR)/message.o \
	$(BUILD_DIR)/process.o \
	$(BUILD_DIR)/prompt.o \
	$(BUILD_DIR)/tool.o \
	$(BUILD_DIR)/session.o \
	$(BUILD_DIR)/cli.o \
	$(BUILD_DIR)/print_mode.o \
	$(BUILD_DIR)/vm.o

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): $(BUILD_DIR) $(OBJECTS)
	$(CC) $(LDFLAGS) -o $@ $(OBJECTS) $(LOCAL_LDFLAGS)

$(BUILD_DIR)/main.o: src/main.c include/psi/common.h include/psi/runtime.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/agent.o: src/core/agent.c include/psi/agent.h include/psi/anthropic.h include/psi/common.h include/psi/session.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/common.o: src/core/common.c include/psi/common.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/anthropic.o: src/core/anthropic.c include/psi/anthropic.h include/psi/common.h include/psi/prompt.h include/psi/session.h include/psi/tool.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/host_ops.o: src/core/host_ops.c include/psi/common.h include/psi/host_ops.h include/psi/session.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/message.o: src/core/message.c include/psi/common.h include/psi/message.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/process.o: src/core/process.c include/psi/common.h include/psi/process.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/prompt.o: src/core/prompt.c include/psi/common.h include/psi/prompt.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/tool.o: src/core/tool.c include/psi/common.h include/psi/tool.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/session.o: src/core/session.c include/psi/common.h include/psi/message.h include/psi/session.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/cli.o: src/runtime/cli.c include/psi/common.h include/psi/runtime.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/print_mode.o: src/runtime/print_mode.c include/psi/common.h include/psi/message.h include/psi/runtime.h include/psi/session.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/vm.o: src/scheme/vm.c include/psi/common.h include/psi/vm.h
	$(CC) $(CPPFLAGS) $(LOCAL_CPPFLAGS) $(BASE_CFLAGS) $(CFLAGS) -c $< -o $@

install: $(TARGET)
	mkdir -p $(DESTDIR)$(BINDIR) $(DESTDIR)$(INCLUDEDIR)/psi $(DESTDIR)$(SHAREDIR)
	cp $(TARGET) $(DESTDIR)$(BINDIR)/psi
	cp include/psi/*.h $(DESTDIR)$(INCLUDEDIR)/psi/
	cp scheme/boot.scm $(DESTDIR)$(SHAREDIR)/boot.scm

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all clean install
