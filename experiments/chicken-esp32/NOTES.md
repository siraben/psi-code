# Chicken Scheme on ESP32 — feasibility notes

Asked: can we replace the embedded Lua VM with Chicken Scheme on the
ESP32, and port psi's dynamic functionality (system-prompt builder,
hooks) into Scheme?

Short answer: **the user code path works, the runtime path does not
without significant porting work**, and even with that work the
memory profile is too heavy for a no-PSRAM ESP32-D0WD-V3.

## What worked

- `csc -c -t hello.scm -o hello.c` produces a portable 8 KB C file
  that pulls in only `chicken.h` (a header of macros + types).
- That `.c` file cross-compiled cleanly with `xtensa-esp32-elf-gcc`
  using just `-DNO_DLOAD2 -DNO_POSIX_POLL -DC_BIG_ENDIAN=0`. 13 KB
  object. So Chicken's *output* is portable to xtensa.

## What did not

`runtime.c` (Chicken's core: GC, primops, top-level dispatcher) needs
a long list of POSIX-hosted facilities that the xtensa-esp-elf newlib
doesn't have:

| symbol / header                  | what newlib gives                           |
| -------------------------------- | ------------------------------------------- |
| `<sysexits.h>`                   | absent (BSD-only)                           |
| `<poll.h>` / `poll()`            | absent                                      |
| `setitimer()`                    | absent (no signal-based profile timer)      |
| `timezone` extern                | absent (only `tzset()` + `localtime`)       |
| `getrusage()`                    | absent                                      |
| `sigaction()` w/ SIGFPE/BUS/SEGV | partial (stack-overflow detection breaks)   |
| `C_resolve_executable_pathname`  | needs a platform impl (`/proc/self/exe` etc) |
| `dlopen()` / `dlsym()`           | absent — must compile with `-DNO_DLOAD2`    |

Each is patchable with a stub. The cascade peeled about 8 layers deep
before I stopped — see `cross-compile.sh` for the reproducer. A real
port would write a `Makefile.esp32` analogous to `Makefile.android`,
stub the missing symbols, and disable the GC's stack-direction
detection (Chicken probes the C stack growth direction and pins
addresses; on FreeRTOS task stacks the bound is shorter and not
contiguous with main).

## What would still hurt afterward

Even with a clean port:

- **Code footprint**: libchicken on macOS arm64 is 7 MB total. With
  `-Os`, dead-code elim, and no `posix-static.o` / `tcp-static.o` /
  `irregex-static.o`, a minimal runtime is 400–500 KB. The 2 MiB
  factory partition holds it, but psi's app-binary already runs at
  1.5 MB; we'd have ~50 KB of headroom.
- **RAM footprint**: Chicken's Cheney GC needs from-space + to-space.
  Default nursery is 64 KB; tenured starts at 1 MB. Tunable down, but
  the *minimum* practical pair is ~32 KB + 32 KB = 64 KB just for the
  GC. Plus the C stack chunks Chicken keeps. On this hardware
  (largest contiguous free block: 110 KB after WiFi+TLS init), that
  leaves almost no room for anything else.
- **Loss of dynamic eval**: Chicken's `eval` is in `eval.c` (24 K
  lines). Compiling it for xtensa is feasible but pulls in another
  ~250 KB of code, plus the macro expander wants some filesystem.
  Without eval we lose the dynamism the port was meant to enable.

## Better path (proposed)

[**chibi-scheme**](https://github.com/ashinn/chibi-scheme) is the
right answer for this hardware:

- ~50 KB compiled core (vs Chicken's 400–500 KB)
- Has `eval` and runtime module loading
- Designed explicitly for embedding in C
- Already used on microcontrollers (e.g., RIOT-OS port)
- BSD license

A future iteration of this experiment would swap `lua-cmod` for a
`chibi-cmod` ESP-IDF component that vendors chibi's source the same
way, exposes `psi.eval(...)` from C, and ports the system-prompt
builder + a few hooks. The Lua side stays as a fallback.

## Files in this directory

- `hello.scm` — the toy program we tried to compile.
- `cross-compile.sh` — reproducer, runs in docker espressif/idf:v5.5.
- `NOTES.md` — this file.
