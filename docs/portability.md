# psi portability

The portability goal is simple: keep the shared runtime buildable wherever a C
compiler and Lua can be made available. The model follows the spirit of Nils
Holm's *Scheme 9 from Empty Space* (S9fES), but psi is not a literal
`cc *.c -o psi` project. It embeds Lua/docs at build time and links Lua 5.5,
cJSON, argtable3, libcurl, zlib, pthread, and optionally libedit.

The code is organized so a porter can replace one host-facing piece at a time
and leave the Lua runtime alone.

## Principles applied (S9fES-derived)

1. **ANSI C89 baseline.** The normal build line is
   `-std=c89 -pedantic -Wall -Wextra -Werror`.
   No `bool`, no `//` comments, no `<stdint.h>`, no VLAs, no
   designated initializers, no compound literals, no anonymous
   structs in the portable core. C89 because that's the floor every C
   compiler since 1989 has agreed on. The Cosmopolitan APE Windows path
   is gated by `PSI_HAVE_COSMO_DCE` and uses Cosmopolitan's NT ABI
   declarations, including fixed-width integer types, only inside that
   port-specific block.

2. **No assumptions about integer width or endianness.** No
   `sizeof(long) == 8` baked in, no `htonl`/`ntohl`, no byte-order
   shuffling. Mixed-width hosts, such as 32-bit `size_t` on a 64-bit
   machine, should work unless an upstream dependency breaks first.

3. **POSIX is isolated, not gone.** Public headers avoid POSIX-only includes,
   and `src/core/process.c` keeps the process backend behind platform branches.
   The current Unix build still uses POSIX headers in implementation files
   (`dirent`, `stat`, `fcntl`, pthread/curl, and terminal APIs), so a new
   non-POSIX port must replace those host shims.

4. **Platform-specific code should live in dedicated files.** The current tree
   ships the portable core plus Linux-oriented build packaging. A new platform
   should add its own `<plat>/src/*.c`; upstream sources should stay untouched.
   This mirrors S9fES's `s9core` plus `s9-unix.c` / `s9-win32.c` split.

5. **Lua runtime, C host.** About 23 KLoC of Lua in `lua/psi/*.lua` contains the
   agent loop, session persistence, rendering, and command parsing. The C layer
   is host glue: about 9 KLoC including headers. Porting should replace C glue,
   not Lua logic.

6. **Detect features, not platforms, when feasible.** Prefer testing for a file,
   syscall, or environment variable over testing for a platform name macro. Same
   idea as S9fES's `#ifdef HAVE_X` guards.

## Audit findings (current tree)

| What we checked                       | Status |
|---------------------------------------|--------|
| C89 strict                            | ✅ portable core; Cosmopolitan DCE has a gated NT ABI block |
| `bool`/`stdint.h`/VLA                 | ✅ no `bool`/VLA; `<stdint.h>` only in the gated Cosmopolitan Windows process backend |
| `//` comments                         | ✅ none|
| Endianness assumptions                | ✅ none; verified by treewide audit: no byte-order primitives (`htonl`/`bswap`/`__builtin_bswap`), no shift-assemble of multi-byte ints from byte streams, no integer-over-byte unions, no `*(uint32_t*)buf` type punning, no raw-int `fwrite`/`fread`. Embedded blobs (Lua bytecode + docs + CA bundle) are zlib-compressed byte streams, byte-order independent. |
| `sizeof(long)` assumptions            | ✅ none|
| Hardcoded paths                       | `/bin/sh`, `/dev/null` (TUI only), and `/dev/urandom` in the Unix random backend |
| Lua shelling out for filesystem work  | avoided for built-in read/write/listing, sessions, prompt templates, and extensions; path joins, parent dirs, recursive mkdir, file type, and directory listing are C-backed primitives |
| `errno` constants beyond C89 set      | `EAGAIN`, `EWOULDBLOCK`, `EINTR`; all POSIX, all universally present |
| `gettimeofday` (POSIX-2001-obsoleted) | one site in `http_async.c` for `pthread_cond_timedwait` deadline; pthread is already required there, so the dependency is fine where it sits |
| `nanosleep`                           | POSIX-1b; universal on modern Unices |
| `sigaction` / `sigemptyset`           | POSIX; universal |
| `fork` / `execl` / `pipe` / `waitpid` | POSIX; gated by `#ifndef _WIN32` |
| Signal-handler-written flag type      | ✅ `volatile sig_atomic_t` (the only type C89 guarantees safe under signal handlers) |
| `LC_NUMERIC` poisoning                | ✅ TUI mode adopts `LC_CTYPE` only, not `LC_ALL`; keeps `printf("%f")` and cJSON locale-neutral so JSON request bodies stay valid |
| Public-header dependency footprint    | ✅ `include/psi/*.h` only pulls `<stddef.h>`, `<signal.h>`, `<stdio.h>`, `<lua.h>`; no `<curl/curl.h>`, `<pthread.h>`, `<unistd.h>`, or other platform/library headers leak through |
| Vendored vs system deps               | Lua 5.5, cJSON, argtable3, libedit, libcurl, zlib are system-supplied via pkg-config in the maintained Linux build. Hosts without pkg-config can vendor or override per-dep; see "untested-OS predictions" below. |

## Untested-OS predictions

| OS                         | Predicted state | What would likely break |
|----------------------------|-----------------|---|
| **FreeBSD / OpenBSD / NetBSD** | should build out-of-box | `pkg-config` is `pkgconf` on BSDs; `PKG_CONFIG=pkgconf make` works. clang's `-Werror` flags vs GCC's may differ; if so, drop `-Werror`. libedit on OpenBSD is `libedit` package, same as Linux. |
| **OpenBSD + `psi-cosmocc-fat`** | works on OpenBSD 7.3; blocked on current OpenBSD 7.9 | The fat Cosmopolitan APE built by `nix build .#psi-cosmocc-fat` runs directly on OpenBSD 7.3. On OpenBSD 7.9, both the APE file and an assimilated ELF abort before `main` because the kernel's pinned-syscall enforcement rejects Cosmopolitan's syscall stubs (`PINS getpid` / `PINS write` in `ktrace`). This is below psi's C/Lua boundary; use a native OpenBSD build for 7.9 until the cosmocc toolchain emits OpenBSD syscall pin metadata. |
| **macOS**                  | should build with Homebrew deps | Homebrew installs Lua and libcjson under `/opt/homebrew`; user must set `PKG_CONFIG_PATH` for a Lua 5.5 package or override `LUA_PKG_CONFIG`. Apple Clang's `-Wno-unknown-warning-option` may eat newer flags silently. `-Wl,-static` is partly broken on macOS, so static builds fail as documented. |
| **illumos / Solaris**      | needs minor work | `gettimeofday` still present but Solaris `pthread_cond_timedwait` semantics differ subtly around CLOCK choice. More importantly, Solaris `getopt_long` is in `libgetopt`; argtable3 vendors getopt so this is fine. |
| **Cygwin / MSYS2**         | should build, slowly | fork is emulated and slow; agent feels sluggish but works. libcurl and pthread present via packages. PE-format static linking has gotchas. |
| **Haiku**                  | plausible, not currently checked in | The repo no longer carries `haiku/` port artifacts. Expect pkg-config/package-name fixes and termios/libedit details before claiming support. |
| **Windows (Cosmopolitan APE)** | runs via `packages.psi-cosmocc-fat` | This is the supported Windows path today: a fat APE executable built by the flake. The Lua runtime uses feature/env detection to route shell-string commands through `cmd.exe` when it observes a Windows host, while keeping POSIX behavior unchanged elsewhere. |
| **9front**                 | target, unverified in this tree | requires non-POSIX process, HTTP, filesystem, and terminal shims. |
| **Windows (MSVC native)**  | does not build | `process.c`'s `_WIN32` arm is empty. Need CreateProcess-based replacement plus a libcurl-or-WinHTTP HTTP backend. ~500 LoC of C. |
| **plain MS-DOS / DJGPP**   | unsupported | no fork, no pthread, no full POSIX. Out of scope. |
| **Embedded (no fork/exec)**| unsupported | tool-call path requires process spawning. A `--no-tools` mode is possible in theory, but it is not a stated goal. |
| **Plain ANSI C (no POSIX)**| only `lua/` runs   | the `lua/psi/*` agent runtime itself only depends on Lua 5.5. You could embed psi's brain into a C++ host that supplies HTTP and shell-exec via its own primitives. Outside scope of `psi` proper. |

## How to port to a new OS

Suggested pattern:

1. Read `docs/architecture.md` to identify the C↔Lua boundary.
2. Identify the platform shims you need to replace:
   - `src/core/http_buffered.c`: blocking HTTP transport (libcurl on POSIX,
     WinHTTP on Windows, etc.).
   - `src/core/http_async.c`: async streaming transport (pthread
     on POSIX, IO completion ports on Win, etc.).
   - `src/core/process.c`: process spawning (fork/exec on POSIX and
     Cosmopolitan APE; stubbed for native `_WIN32`, which would need
     CreateProcess).
   - `src/core/random.c`: secure random bytes (`/dev/urandom` on Unix,
     platform RNG on other hosts).
   - `src/lua/vm.c`'s `psi.readline` binding: line editor (libedit
     on POSIX, fgets fallback elsewhere).
   - `src/runtime/tui_mode.c`: TUI (termios + ANSI on POSIX; skip on
     constrained platforms).
3. Vendor what isn't already present:
   - Lua 5.5: vendor source, build statically. Watch for the
     `lstrlib.c get_onecapture` size_t/ptrdiff_t bug if your
     platform's `size_t` differs from `ptrdiff_t`.
   - cJSON, argtable3: amalgamation single-file builds, vendor.
4. Write a platform-specific build file (a Makefile fragment, or
   the platform's native build tool).
5. Provide a small bootstrap script that brings up any background
   services your platform needs (auth, listeners, etc.).

The upstream `src/` should not need editing. If it does, file a portability bug.

## Build-system portability

The Makefile assumes:
- GNU `make` (or BSD make with `?=` and `:=`)
- `pkg-config` (or `pkgconf`)
- `lua5.5`, `libcjson`, `libedit`, `libcurl`, `zlib`,
  `argtable3` discoverable via pkg-config

For platforms without pkg-config, override per dependency with
`PSI_CFLAGS_<DEP>` / `PSI_LIBS_<DEP>` environment variables
(`PSI_CFLAGS_LUA`, `PSI_LIBS_LUA`, etc.). Each pkg-config call falls through to
those overrides, so the build never fails only because pkg-config is missing.

## Non-goals

- Run on 16-bit systems. S9fES draws the line at 32-bit; we follow.
- Support `bool` from `<stdbool.h>` or any C99-only feature.
- Promise more than what the platform's libc and (optionally) pthread
  give us. No threading abstraction layer, no ABI-stable plugin API.
- Hide platform differences inside Lua. Tool descriptions should reflect the
  actual host shell. It is cheaper to tell the model the truth than to emulate
  one shell on top of another.
