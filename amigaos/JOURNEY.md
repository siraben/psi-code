# AmigaOS port journey

This is the running journal for porting psi to AmigaOS, mirroring
`haiku/JOURNEY.md`. Decisions, dead-ends, gotchas, resume notes.

## Target choice

Three Amiga targets exist; picking which to chase first matters.

| Target | Arch | Status | Toolchain | Networking | Notes |
|---|---|---|---|---|---|
| AmigaOS 3.x ("Classic") | m68k | Released 2018-21 (3.1.4 / 3.2) | vbcc, bebbo gcc | bsdsocket.library + AmiSSL or Roadshow | Most software, biggest community |
| AmigaOS 4.x | PowerPC | Niche; SAM/AmigaOne hardware | adtools-ppc | bsdsocket.library | Tiny user base |
| MorphOS | PowerPC | Active; Mac mini G4/G5 | gcc-ppc | OpenSSL native | Active, less iconic |
| AROS | x86 / m68k / arm | Open re-implementation | gcc native | host stack | Easier but feels like cheating |

**Pick: classic AmigaOS 3.2 / m68k.** Reasons:

1. The iconic target. "psi on a 68k Amiga" is the demo.
2. Cross-compile works fine on Linux; no need for actual hardware.
3. A user-space emulator (`vamos` from `amitools`) lets us run 68k
   binaries without Kickstart ROMs — fully autonomous, no ROM
   licensing question.
4. psi's coroutine-based scheduler maps neatly onto AmigaOS's
   cooperative `Process` model. Easier conceptual fit than the
   pthreads + signals world we have on Haiku/Linux.

## Toolchain choice

Two main cross-toolchains:

1. **bebbo/amiga-gcc** — modern GCC 6.5/9, includes NDK 3.9, AmiSSL
   headers, libnix. Big build (~30 min), best output quality. Has a
   Makefile-driven build at <https://github.com/bebbo/amiga-gcc>.
2. **vbcc + vasm + vlink** — Volker Barthelmann's freeware toolchain.
   Tiny, fast, well-maintained, the canonical "no-fluff" cross-build.
   <http://sun.hasenbraten.de/vasm/>, <http://sun.hasenbraten.de/vlink/>,
   <http://www.compilers.de/vbcc.html>.

**Start with vbcc.** Smaller surface, builds in seconds, ports of Lua
already exist using vbcc. If something requires GCC (e.g. C99
features vbcc lacks, or libcurl / OpenSSL), upgrade to bebbo's gcc
later. Both are nixpkgs-absent — I'll write a small flake fragment.

## Emulation choice

For autonomous testing we want headless and license-clean.

- **vamos** (part of `amitools` on PyPI, MIT) — userspace stub of
  AmigaOS for running m68k binaries directly. No Kickstart ROM, no
  filesystem image. Hooks `OpenLibrary`, `Read`, `Write`, etc. by
  name and dispatches to host. **Best autonomous option.**
- **FS-UAE** — full system emulator. Needs a Kickstart ROM (3.1 or
  3.2; 3.1 ROM redistributable via Hyperion's free 3.1 download or
  AROS-m68k ROM replacement) and a Workbench image.
- **WinUAE under Wine** — same; needs ROMs.

**Pick: vamos for autonomous testing**, FS-UAE optional for a real
desktop demo if I want to take a screenshot at the end. vamos is
sufficient to validate `psi --print` / `--agent` non-TUI modes.

## What likely won't port (early hypothesis)

The classic Amiga doesn't have:

- POSIX threads → use AmigaOS `CreateNewProc` / `Task`. psi's
  scheduler is already coroutine-based; should fit.
- POSIX `select` on TCP → bsdsocket.library uses BSD-style
  `WaitSelect`. Doable.
- libcurl + OpenSSL → has been ported (AmigaOS 3 port of curl exists,
  using AmiSSL). May need to vendor a thinner HTTP+TLS client.
- ncurses → no terminal; use AmigaDOS `console.device` with raw
  ANSI. Skip TUI mode entirely; print/REPL only on first pass.
- libedit → no readline; use simple `Read` from stdin.
- mmap → no MMU on 68000-class machines. psi doesn't really need it;
  static buffers are fine.
- pthread mutex / condvar → no preemptive threads, no need.
- Filesystem path syntax → AmigaDOS uses `Volume:Dir/file`, not
  `/path`. Most psi paths are user-supplied so we can leave it; the
  internal default-session-path in `~/.local/state/psi/sessions/` will
  need a tweak (no `$HOME`-style env on Amiga; use `T:` or `RAM:`
  conventions, or `ENV:psi/sessions`).

Realistic v1 scope: `psi --print` / `--eval` / `--system-prompt` and
maybe `--agent` against Anthropic. No TUI, no compaction-from-disk,
no extensions. Just enough to demonstrate "psi computed something on
a 68k Amiga".

## Plan

1. Write `amigaos/flake.nix` (or extend the root one) with vbcc +
   vasm + vlink + amitools/vamos overlays.
2. Compile a "Hello, world!" classic Amiga executable; run under
   vamos.
3. Cross-compile Lua 5.4 statically for 68k; run `print("hi")` under
   vamos.
4. Audit psi for 68k blockers; produce a porting punch-list.
5. Pick a tractable subset (likely `--print` mode) and stub out the
   rest. Bring up agent against Anthropic if HTTP works.

Each milestone: append to this file with what worked, what didn't,
what the next step is.

---

## Phase 0 — workspace init

Created `amigaos/` folder. Wrote this file. Tracking work in psi's
TaskCreate sidecar (tasks #112–#116).

## Phase 1 — toolchain via Nix flake

Wrote `amigaos/flake.nix` with three derivations + a `symlinkJoin`
aggregate:

- `vasm-m68k` — `vasm` with `CPU=m68k SYNTAX=mot`, output is the
  Motorola-syntax m68k assembler `vasmm68k_mot`.
- `vlink` — multi-format linker, supports Amiga HUNK and ELF.
- `vbcc-m68k` — the C compiler frontend driven by `vc`.
- `amiga-toolchain` — `pkgs.symlinkJoin` that aggregates the three
  into one $out/bin so `nix develop .#cross` puts everything on PATH.

All three are nixpkgs-absent so the flake fetches upstream tarballs
from <http://sun.hasenbraten.de/> and <http://www.ibaug.de/vbcc/>
with hashes pinned in the flake. License is "freeware" → marked as
`licenses.unfree`; build needs `NIXPKGS_ALLOW_UNFREE=1` (or
`nixpkgs.config.allowUnfree = true`).

### Gotchas hit while writing the flake

1. **GCC 14 default-promotes implicit-function-declaration to error.**
   vbcc is C89-era code with informal forward refs. Fixed via
   `-Wno-error=implicit-function-declaration -Wno-error=int-conversion
   -Wno-error=incompatible-pointer-types -Wno-error=implicit-int`
   on the `CC` make-variable override.

2. **nixpkgs stdenv injects `-Werror=format-security`** through its
   `format` hardening pass. vbcc's `frontend/vc.c` has many
   `printf(literal_var)` patterns that trip it. The CC flag override
   *cannot* turn this off because the hardening flags come *after* my
   user CFLAGS in the gcc spec. The fix is `hardeningDisable = [
   "format" "fortify" ];` at the derivation level.

3. **vbcc's Makefile doesn't honour parallel make**: `-j4` races on
   `objects/m68k/dt.h` generation (dtgen runs before the directory
   exists). Stick with serial `make` — the build is short enough.

4. **Nix flakes only see git-tracked files.** First few build attempts
   re-used the cached failed-derivation hash because my edit to
   `flake.nix` wasn't `git add`ed. `git add` after every flake edit.

5. **`nix log <drv>` only shows logs for builds that completed in this
   nix daemon's lifetime**, even for failed builds. Cached failures
   from a previous boot are gone. When debugging an iterative flake
   change, make a trivial edit (whitespace) so the drv hash changes
   and force a rebuild.

### Status

- `vasm-m68k` ✅ builds
- `vlink` ✅ builds
- `vbcc-m68k` ✅ builds (after `hardeningDisable = ["format" "fortify"]`,
  `-fno-asm`, and a `yes ""` pipe to dtgen)
- `vbcc-target-m68k-amigaos` ✅ builds (lha-extracted)
- `amiga-toolchain` ✅ aggregate works; config rewriting maps
  AmigaDOS volume assigns (`vincludeos3:` / `vlibos3:`) to real
  on-disk Nix store paths
- `amitools` (vamos) — derivation written but hash placeholder.
  Will lock when needed.

### Extra gotchas hit on the way to first executable

6. **`dtgen` is interactive.** vbcc's `bin/dtgen` (the datatype-table
   generator that the Makefile invokes during build) prompts
   `Type y or n [y]: ` for each datatype it discovers and reads from
   stdin. In a Nix sandbox there's no TTY, `fgets` hits EOF and the
   `do-while` loop spins on uninitialised memory — observed: 30+ min
   pegging a CPU, build never makes progress.
   Fix: pipe `yes ""` into the make invocation so each prompt's
   default is accepted. Then run `make` again unpiped to surface
   real errors after the dtgen-stage artifacts (`dt.h` / `dt.c`)
   exist.

7. **`-std=gnu89` makes `asm` a keyword.** vbcc's `supp.h` declares
   `Var *declare_builtin(..., char *asm);` — fine in strict C89, but
   gnu89 promotes `asm` to a reserved word. `-fno-asm` restores the
   identifier sense.

8. **Shipped `aos68k` config uses AmigaDOS volume assigns.** The
   default `vc` driver config has `-Ivincludeos3:` / `-Lvlibos3:`
   which only resolve on a real Amiga (or one with assigns set up).
   On Linux, vbcc passes them through verbatim and the C frontend
   reports "stdio.h not found".
   Fix: in `amiga-toolchain` (the symlinkJoin aggregate), the
   `postBuild` rewrites the three configs (`aos68k`, `aos68km`,
   `aos68kr`) replacing `vincludeos3:` and `vlibos3:` with the real
   on-disk paths inside `targets/m68k-amigaos/include` and `lib`.
   `symlinkJoin` links files in read-only, so the config link is
   removed first and the rewritten copy written in its place.

9. **`vc` invokes `delete quiet …` to clean intermediates.** That's
   the AmigaDOS `delete` command, not Linux `rm`. Harmless — the
   intermediate cleanup is best-effort and the executable is
   produced fine. Could provide a `delete` shim wrapper if it ever
   matters; for now we just see a "command not found" warning.

## Phase 2 — first executable

```
$ cd amigaos
$ NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#amiga-toolchain
$ export VBCC=$PWD/result PATH=$PWD/result/bin:$PATH
$ cd examples
$ vc +aos68k -o hello hello.c
$ file hello
hello: AmigaOS loadseg()ble executable/binary
```

Header bytes:
```
00 00 03 f3   ← HUNK_HEADER (0x3f3)
...
56 42 43 43 20 30 2e 39   ← "VBCC 0.9" identifier
```

Real AmigaOS HUNK format. Now to actually run it.

## Phase 3 — vamos packaging + first execution

amitools provides `vamos`, a userspace m68k AmigaOS emulator. It
hooks `exec.library` / `dos.library` calls and dispatches them to
the host — so we can run AmigaOS binaries directly without a
Kickstart ROM or filesystem image. Two Python packages:

- `machine68k` — Cython bindings around the Musashi 68k core.
- `amitools` — vamos itself, plus `xdftool` / `hunktool` etc.

### Gotchas

10. **`amitools` setup uses `setuptools_scm`** for version inference
    from git tags. The fetched tarball has no `.git`, so the build
    bails. Fix: `SETUPTOOLS_SCM_PRETEND_VERSION = "x.y.z"` env var
    in the derivation. Same trick on `machine68k`.

11. **`amitools` 0.8.1 release calls `Traps.set_exc_func()`** but
    the newest released `machine68k` (0.4.1) doesn't expose that
    method. Released-pair mismatch. Fixed by pinning amitools to a
    `main`-branch commit (`3b57f205…`) where `_setup_handler` was
    rewritten to use the API `machine68k` 0.4.1 actually has.

12. **`amitools` requires `greenlet`** but doesn't list it in its
    setup metadata (or the tarball strips it). Add explicit
    `python3Packages.greenlet` to `propagatedBuildInputs`.

13. **`amitools` ships an `lhafile` requirement** that's nixpkgs-
    absent. It's only used by `xdftool` / `xdfscan` (ADF/HDF disk
    image tooling) — `vamos` itself doesn't import it. Drop from
    `propagatedBuildInputs`.

### First execution

```
$ cd amigaos
$ nix build .#amitools .#amiga-toolchain
$ vc +aos68k -o examples/hello examples/hello.c   # via amiga-toolchain
$ result/bin/vamos examples/hello
hello from psi on m68k AmigaOS!
```

That's a real 68k AmigaOS HUNK executable, executed by a Musashi-
based userspace emulator with no Kickstart ROM, on x86_64 Linux.

## Phase 4 — Lua 5.4 cross-compile

`flake.nix` now has `lua-amigaos` that builds Lua 5.4.7's `liblua.a`
+ the `lua` interpreter binary against the vbcc toolchain.

### What worked

- `make a` (the bare static-lib target — no platform preset like
  `linux` / `macosx` to avoid dragging in POSIX headers).
- vbcc-friendly CFLAGS:
  - `-O=1` (vbcc's optimisation form; `-O2` is rejected
    syntactically + duplicate `-O` would conflict with the config).
  - `-DLUA_USE_C89` to disable `popen`, `mkstemp`, etc.
  - **NOT** `-DLUA_USE_POSIX=0` — Lua tests `#if defined(LUA_USE_POSIX)`
    so even setting it to 0 enables POSIX! Just don't define it.
  - `WARN=""` `SYSCFLAGS=""` to strip the Makefile's `-Wall -Wextra`
    (vbcc doesn't recognise GCC warning flags).
- Linking: `vc +aos68k -o lua lua.o liblua.a -lmieee -lamiga`.
  - `-lmieee` for `MathIeeeDoubBasBase` / `MathIeeeDoubTransBase`
    library globals (vbcc's double math goes through AmigaOS's IEEE
    Math libraries even when `-amiga-softfloat` is set; softfloat
    only changes the FPU usage, not the math-base linkage).
  - `-lamiga` for the exec/dos bridge.

### Gotchas

14. **`-O=1 -O2` conflict.** vbcc rejects multiple `-O` flags. Lua's
    Makefile passes `-O2` by default; my `MYCFLAGS` adding `-O1`
    triggered "Optimization flags specified multiple times".

15. **GCC warning flags break vbcc.** `-Wall` → "Unknown Flag <-Wall>".
    Override `WARN=""` in `make` invocation.

16. **`-DLUA_USE_POSIX=0` actually enables POSIX.** Lua's source tests
    `#if defined(LUA_USE_POSIX)` not `#if LUA_USE_POSIX`. So
    `-DLUA_USE_POSIX=0` defines it (to 0, but defined). Headers
    pulled in: `<sys/wait.h>`, which vbcc's NDK doesn't have. Drop
    the define entirely.

17. **`vc` config calls `delete quiet …`** to remove intermediate
    `.asm` files. AmigaDOS-only command. Patched the rewritten
    config in `amiga-toolchain.postBuild` to use `rm -f` instead.

18. **vbcc's `-amiga-softfloat` doesn't make math standalone.** It
    avoids using the FPU but **still** routes `double` math through
    AmigaOS's `MathIeeeDoubBas/Trans` library bases (referenced via
    globals `_MathIeeeDoubBasBase` / `_MathIeeeDoubTransBase`).
    Those are provided by `mieee.lib`, not `msoft.lib`. Linking
    needs `-lmieee` for any code that does `double` arithmetic
    (Lua's number type is double).

### First Lua execution

```
$ result-tools/bin/vamos -- result/bin/lua -e '
    local function fib(n) return n < 2 and n or fib(n-1)+fib(n-2) end
    print("fib(10) = " .. fib(10))
    print(_VERSION)'
fib(10) = 55
Lua 5.4
```

That's a real Lua 5.4.7 PUC-Rio interpreter, ELF-free 68k AmigaOS
HUNK binary, executing recursion + closures + table ops on a
userspace m68k emulator. **235 KB stripped.**

The `--` separator before the executable matters: vamos eats `-e`
as its `--hw-exception` flag if you let it, swallowing Lua's `-e`.

## Phase 5 — psi portability audit

What in psi's C layer won't survive a vbcc/m68k-amigaos build:

| File | LOC | Blocker | Severity |
|---|---|---|---|
| `src/core/http_async.c` | 372 | pthread + libcurl | hard — both absent |
| `src/core/anthropic.c` | 170 | libcurl | hard |
| `src/core/process.c` | 380 | fork/exec/select | hard — AmigaOS uses `Execute()` / `SystemTagList()` |
| `src/runtime/tui_mode.c` | 2707 | ncurses (~9 includes) | medium — drop entirely; print/REPL only |
| `src/lua/vm.c` | many | libedit, ncurses bridge | medium — REPL via plain `Read()` |
| `src/runtime/print_mode.c` | 146 | minor stdio things | easy |
| Lua modules | ~5000 | none | none — already proven to compile |

### Rough porting plan

**v1 — `psi --eval` only.** No HTTP, no agent, no TUI. Just runs a
Lua expression and prints. Validates the integration: vbcc + Lua
+ a tiny C shim. Likely a 300-LOC `main.c` that calls
`luaL_newstate`, opens libs, runs `--eval` from argv. Already
proven by my standalone Lua interpreter test above.

**v2 — `psi --print` + minimal REPL.** Add `Read()` based REPL
loop to replace libedit. No ncurses. Maybe ANSI escape codes for
colours via `Write()` directly. Print mode pulls in the system
prompt, agents.md discovery — all portable Lua.

**v3 — networking (the hard part).**
- Option A: bsdsocket.library + AmiSSL + a hand-rolled tiny HTTP
  client. Lots of work. AmiSSL probably doesn't run under vamos
  cleanly.
- Option B: stub HTTP via vamos's host bridge — invent a "hostnet"
  syscall that vamos forwards to the host's `curl`. Lets us
  prototype on Linux without ever opening sockets in the m68k
  binary. Honest demo for vamos; doesn't work on real Amiga.
- Option C: leave networking out; ship `psi-amiga` as a Lua
  evaluator + session-on-disk reader. The agent loop runs on a
  beefier machine that pipes JSON-over-pipe to vamos.

**Realistic v1 ship:** vbcc + Lua + a 100-line `main.c` that
exposes `--eval` / `--print` modes only. Bundled with vamos as a
"psi-on-Amiga demo". v3 networking is a separate adventure.

### Status snapshot

```
amigaos/
├── flake.nix          ← vbcc + vasm + vlink + amitools + lua-amigaos
├── flake.lock
├── JOURNEY.md         ← this file
└── examples/
    ├── Makefile
    └── hello.c        ← compiles + runs under vamos
```

Build + run dance:
```
NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#amiga-toolchain --out-link result
NIXPKGS_ALLOW_UNFREE=1 nix build --impure .#lua-amigaos     --out-link result-lua
nix build .#amitools --out-link result-vamos

# Hello world.
result/bin/vc +aos68k -o /tmp/hello examples/hello.c
result-vamos/bin/vamos -- /tmp/hello

# Lua expression.
result-vamos/bin/vamos -- result-lua/bin/lua -e 'print("hi")'
```

## Phase 6 — `psi --eval` v1 ships

Wrote `amigaos/psi-shim/main.c` (~140 LOC). Two modes:

- `--eval EXPR`  — run a Lua expression, print the result.
- `--print TEXT` — call `psi.prompt.handle_print(TEXT)` if available,
  else echo. Pre-Lua-bootstrap fallback exists.
- `--version`    — banner.

Linked the same way `lua-amigaos` builds its interpreter:
`vc +aos68k -o psi main.o liblua.a -lmieee -lamiga`. Result is a
**231 KB AmigaOS HUNK executable**.

```
$ result-tools/bin/vamos -- result/bin/psi --version
psi 0.1.0 (AmigaOS m68k, Lua Lua 5.4)

$ result-tools/bin/vamos -- result/bin/psi --eval "1 + 2 * 3"
7

$ result-tools/bin/vamos -- result/bin/psi --eval 'string.upper("hello, m68k")'
HELLO, M68K

$ result-tools/bin/vamos -- result/bin/psi \
    --eval 'local t={}; for i=1,3 do t[i]=i*i end; return table.concat(t,",")'
1,4,9
```

The `run_eval` helper first tries `return EXPR` (so `1+2+3` prints
without explicit return). If that fails to parse — typical for
multi-statement input with `local`s — it falls back to running the
input as a chunk; any explicit `return` value bubbles up to the
top of stack and prints.

### Status

5 milestones done:

- ✅ vbcc + vasm + vlink + target package, all in `flake.nix`
- ✅ AmigaOS m68k hello-world compiles to HUNK
- ✅ vamos runs HUNK binaries on Linux without ROMs
- ✅ Lua 5.4.7 cross-compiles cleanly (235 KB interpreter)
- ✅ psi v1 (`--eval` / `--print`) shim — 231 KB, runs Lua

Total flake LOC: ~325. Total build artefact for psi+lua: ~470 KB
of m68k HUNK. Boot Lua eval under vamos in <1 second on a modern
host.

Next plausible moves:

1. **Bundle psi's own Lua modules.** Currently `psi.prompt.handle_print`
   is unavailable — the shim's REPL fallback fires. Need to embed
   `lua/psi/*.lua` into the binary (similar to how psi-Linux uses
   `embed_lua.c`) so the AmigaOS build is self-contained.
2. **Networking.** Hardest blocker. Three options laid out in the
   audit; option B (host-bridge HTTP via vamos) is the most
   tractable for a demo.
3. **Real-hardware run.** Build under `nix build .#psi-amigaos`,
   `scp` the binary to a 68k Amiga (real or FS-UAE with Kickstart
   3.x), see it run there too. Mostly a victory lap.

The flake is the canonical reproducer: `nix build .#psi-amigaos`
then `nix run .#amitools -- vamos -- result/bin/psi --eval EXPR`
on any Linux host. No ROMs, no manual tarball pulls, fully
reproducible from git.

## Phase 7 — embedded Lua modules

`psi --print` now runs the real `psi.prompt.handle_print` from
`lua/psi/prompt.lua` inside the m68k binary. **No filesystem
access** — every Lua module is baked into the executable.

### Pieces added

- `amigaos/scripts/embed_lua_raw.c` — host tool. Same output
  schema as `scripts/embed_lua.c` (the `psi_embedded_lua` struct
  with `name`/`src`/`len`/`raw_len`) but emits raw byte arrays
  with `len == raw_len` so the runtime can skip zlib. The m68k
  binary doesn't need libz.
- `embed-lua-raw` derivation in `flake.nix` — host build of
  the above. Runs at build time.
- `psi-amigaos` derivation now bundles 19 Lua modules (boot.lua
  + lua/psi/*.lua) by piping them through `embed_lua_raw` then
  cross-compiling the resulting C array with vbcc.
- `amigaos/psi-shim/main.c` — installs a custom searcher into
  `package.searchers[2]` mirroring `psi_vm_embedded_searcher` in
  `src/lua/vm.c` (minus inflation). Stubs out the C primitives
  the bundled `psi.prompt` needs (`psi.version`, `psi.cwd`,
  `psi.session_message_count`, etc.) since those normally come
  from `vm.c`'s PSI_REG block.

### Gotchas

19. **vbcc rejects implicit `strdup`.** Either `string.h` doesn't
    expose the prototype or vbcc's strict mode treats it as int-
    returning. `error 39: invalid types for assignment` on
    `char *p = strdup(s);`. Fix: hand-rolled `psi_strdup` using
    `malloc` + `memcpy`.

20. **`argv` storage isn't stable** on AmigaOS the way it is on
    POSIX. vbcc's `aos68k` startup parses the DOS command line
    into argv, but the underlying buffer is reused once dos.library
    activity (or Lua's io setup) advances. By the time a function
    deep in a Lua call uses `argv[2]`, the bytes are gone.
    Symptom: `lua_pushstring(L, argv[2])` pushed an empty string;
    Lua received `""` for any arg called late in main.
    Fix: snapshot `argv[1]` and `argv[2]` to heap copies (`psi_strdup`)
    immediately at top of main, before any other allocation.

21. **`embed_lua_raw` byte arrays compile slowly.** A 200 KB
    array of `0x..,` literals takes vbcc several seconds to parse
    — much slower than gcc on the same input. Mitigation: drop
    `-O=1` to `-O=0` for the `embedded_lua.o` step; the bytes
    aren't code so optimisation buys nothing.

### Demo

```
$ result-tools/bin/vamos -- result/bin/psi --version
psi 0.1.0 (AmigaOS m68k, Lua Lua 5.4, embedded modules)

$ result-tools/bin/vamos -- result/bin/psi --print "Hello AmigaOS"
psi bootstrap online
version: 0.1.0 (AmigaOS)
session-messages: 0
prompt: Hello AmigaOS

$ result-tools/bin/vamos -- result/bin/psi --eval "_VERSION"
Lua 5.4
```

That `psi bootstrap online …` block is `lua/psi/prompt.lua`'s
`M.handle_print` running inside a 381 KB m68k AmigaOS HUNK
binary on a userspace 68k emulator. The whole chain — embedder
→ vbcc → vlink → vamos → Musashi → Lua VM → embedded Lua module
→ stdout — is reproducible from `nix build`.

Next: Phase 8 (process spawning) so tools like `bash` / `grep`
can actually do something, then Phase 9 (vamos host-bridge for
HTTP).
