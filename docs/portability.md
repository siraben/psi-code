# psi portability

Aspirations: build cleanly on every platform that has a C compiler
and a Lua interpreter, with as little ceremony as Nils Holm's
*Scheme 9 from Empty Space* (S9fES) — `cc *.c -o psi` and go. We
don't quite get there because psi has more dependencies than S9fES
(it has none beyond `<stdio.h>`/`<stdlib.h>`/`<string.h>`), but the
shape of the code is deliberately set up so an adventurous porter
can replace any one bit and keep the rest.

## Principles applied (S9fES-derived)

1. **ANSI C89, period.** The build line is
   `-std=c89 -pedantic -Wall -Wextra -Werror`.
   No `bool`, no `//` comments, no `<stdint.h>`, no VLAs, no
   designated initializers, no compound literals, no anonymous
   structs. C89 because that's the floor every C compiler since 1989
   has agreed on. Verified by `git grep` and the build.

2. **No assumptions about integer width or endianness.** No
   `sizeof(long) == 8` baked in, no `htonl`/`ntohl`, no byte-order
   shuffling. The Plan 9 port found out the hard way that 9front
   APE has 32-bit `size_t` on a 64-bit machine — and the only place
   that actually broke (Lua 5.4.6's `lstrlib.c`) was upstream code,
   not psi.

3. **POSIX is gated, not assumed.** `src/core/process.c` wraps every
   POSIX include in `#ifndef _WIN32`; the `_WIN32` arm is empty
   today but intentionally leaves a hook for a future
   CreateProcess-based implementation. No `#include <unistd.h>` in a
   header that callers might not need POSIX for.

4. **Platform-specific code lives in dedicated files.** Linux/Haiku
   uses `src/core/anthropic.c` (libcurl) and `src/core/http_async.c`
   (pthread). 9front replaces both with `9front/src/http_webfs.c` and
   `9front/src/http_async_stub.c`. Any new platform adds its own
   `<plat>/src/*.c` and the upstream sources stay untouched. This
   mirrors S9fES's `s9core` + `s9-unix.c` / `s9-win32.c` split.

5. **Lua brain, C scaffolding.** ~5 KLoC of Lua in `lua/psi/*.lua`
   contains the agent loop, session persistence, render, command
   parsing — fully OS-agnostic. The C layer is glue (~3 KLoC). To
   port, you replace C glue, not Lua logic.

6. **Detect features, not platforms** *(when feasible)*. The Plan 9
   detection in `lua/psi/platform.lua` opens `/dev/sysname` instead
   of testing `__plan9__` macros — it's a feature test
   (this-file-exists), not a platform-name test. Same idea as
   S9fES's `#ifdef HAVE_X` guards.

## Audit findings (current tree)

| What we checked                       | Status |
|---------------------------------------|--------|
| C89 strict                            | ✅      |
| `bool`/`stdint.h`/VLA                 | ✅ none|
| `//` comments                         | ✅ none|
| Endianness assumptions                | ✅ none|
| `sizeof(long)` assumptions            | ✅ none|
| Hardcoded paths                       | only `/bin/sh`, `/bin/rc` (with fallback chain), `/dev/null` (TUI only) |
| `errno` constants beyond C89 set      | `EAGAIN`, `EWOULDBLOCK`, `EINTR` — all POSIX, all universally present |
| `gettimeofday` (POSIX-2001-obsoleted) | one site in `http_async.c` for `pthread_cond_timedwait` deadline; pthread is already required there, so the dependency is fine where it sits |
| `nanosleep`                           | POSIX-1b; universal on modern Unices |
| `sigaction` / `sigemptyset`           | POSIX; universal |
| `fork` / `execl` / `pipe` / `waitpid` | POSIX; gated by `#ifndef _WIN32` |
| Vendored vs system deps               | Lua 5.4, cJSON, argtable3, libedit, libcurl, ncurses, zlib are system-supplied via pkg-config on Linux/Haiku; 9front vendors Lua + cJSON + argtable3 and stubs the rest. Makefile assumes pkg-config — see "untested-OS predictions" below. |

## Untested-OS predictions

| OS                         | Predicted state | What would likely break |
|----------------------------|-----------------|---|
| **FreeBSD / OpenBSD / NetBSD** | should build out-of-box | `pkg-config` is `pkgconf` on BSDs — `PKG_CONFIG=pkgconf make` works. clang's `-Werror` flags vs GCC's may differ; if so, drop `-Werror`. libedit on OpenBSD is `libedit` package, same as Linux. |
| **macOS**                  | should build with Homebrew deps | Homebrew installs lua@5.4 and libcjson under `/opt/homebrew`; user must set `PKG_CONFIG_PATH`. Apple Clang's `-Wno-unknown-warning-option` may eat newer flags silently. `-Wl,-static` is partly broken on macOS, so static builds fail — that's documented. |
| **illumos / Solaris**      | needs minor work | `gettimeofday` still present but Solaris `pthread_cond_timedwait` semantics differ subtly around CLOCK choice. More importantly, Solaris `getopt_long` is in `libgetopt`; argtable3 vendors getopt so this is fine. |
| **Cygwin / MSYS2**         | should build, slowly | fork is emulated and slow; agent feels sluggish but works. libcurl and pthread present via packages. PE-format static linking has gotchas. |
| **Haiku**                  | already works | port committed under `haiku/`. |
| **9front (Plan 9)**        | already works | port committed under `9front/`; uses webfs / native rc shell / vendored Lua. |
| **Windows (MSVC native)**  | does not build | `process.c`'s `_WIN32` arm is empty. Need CreateProcess-based replacement plus a libcurl-or-WinHTTP HTTP backend. ~500 LoC of C, similar to the 9front shim set. |
| **plain MS-DOS / DJGPP**   | unsupported | no fork, no pthread, no full POSIX. Out of scope. |
| **Embedded (no fork/exec)**| unsupported | tool-call path requires process spawning. Could in theory build a `--no-tools` mode — not a stated goal. |
| **Plain ANSI C (no POSIX)**| only `lua/` runs   | the `lua/psi/*` agent runtime itself only depends on Lua 5.4. You could embed psi's brain into a C++ host that supplies HTTP and shell-exec via its own primitives. Outside scope of `psi` proper. |

## How to port to a new OS

The pattern from `9front/` and `haiku/`:

1. Read `docs/architecture.md` to identify the C↔Lua boundary.
2. Identify the platform shims you need to replace:
   - `src/core/anthropic.c` — HTTP transport (libcurl on POSIX,
     `webfs(4)` on Plan 9, WinHTTP on Windows).
   - `src/core/http_async.c` — async streaming transport (pthread
     on POSIX, sync stub on Plan 9, IO completion ports on Win).
   - `src/core/process.c` — process spawning (fork/exec on POSIX,
     stubbed for Win, would need CreateProcess).
   - `src/lua/vm.c`'s `psi.readline` binding — line editor (libedit
     on POSIX, fgets fallback elsewhere).
   - `src/runtime/tui_mode.c` — TUI (ncurses on POSIX; skip on
     constrained platforms).
3. Vendor what isn't already present:
   - Lua 5.4: vendor source, build statically. Watch for the
     `lstrlib.c get_onecapture` size_t/ptrdiff_t bug if your
     platform's `size_t` differs from `ptrdiff_t` (patch in
     `9front/patches/`).
   - cJSON, argtable3: amalgamation single-file builds, vendor.
4. Write a platform-specific build file (`mkfile` for Plan 9,
   per-platform Makefile fragment for others).
5. Provide a small bootstrap script that brings up any background
   services your platform needs (auth, listeners, etc. — see
   `9front/tools/fullup.rc`).

The upstream `src/` should *not* need editing. If it does, that's a
portability bug — file it.

## Build-system portability

The Makefile assumes:
- GNU `make` (or BSD make with `?=` and `:=`)
- `pkg-config` (or `pkgconf`)
- `lua5.4`, `libcjson`, `libedit`, `libcurl`, `zlib`, `ncursesw`,
  `argtable3` discoverable via pkg-config

For platforms without pkg-config, set the right `CFLAGS`/`LDFLAGS`
manually. The build system is one of the LEAST portable parts of
psi today — a future cleanup is to allow each pkg-config result to
fall through to user-provided env vars (`PSI_CFLAGS_LUA`,
`PSI_LIBS_LUA`, etc.). Tracked but not yet implemented.

## What we deliberately don't try to do

- Run on 16-bit systems. S9fES draws the line at 32-bit; we follow.
- Support `bool` from `<stdbool.h>` or any C99-only feature.
- Promise more than what the platform's libc and (optionally) pthread
  give us. No threading abstraction layer, no ABI-stable plugin API.
- Hide platform differences inside Lua. The Lua side does host
  detection (`platform.is_plan9()`) and the agent's tool descriptions
  reflect actual host shell — telling an LLM the truth is cheaper
  than emulating bash on rc.
