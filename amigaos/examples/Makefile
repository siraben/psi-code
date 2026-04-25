# Cross-compile m68k AmigaOS hello-world.
#
# Usage:
#   nix develop ../#cross    # drops into a shell with the toolchain
#   make
#
# Or one-shot:
#   nix develop ../#cross -c make

VC      ?= vc
TARGET  ?= +aos68k

CFLAGS   = $(TARGET) -O1
LDFLAGS  = $(TARGET)

all: hello

hello: hello.c
	$(VC) $(CFLAGS) -o hello hello.c

clean:
	$(RM) hello *.o
