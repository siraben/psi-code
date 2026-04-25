# psi on 9front — port journey

Running log of the port to 9front (Plan 9 derivative). Sibling of
`haiku/JOURNEY.md`.

---

## Starting point

The earlier Haiku port's JOURNEY.md said: "psi can't run on Plan 9
without a real port (libcurl/libedit/ncurses/pthread all missing;
Plan 9 has no Linux ABI shim)." That's what we're doing now.

**MVP goal:** a real Anthropic API call succeeds from a 9front VM.

**Strategy:** keep psi's Lua layer (the real brain — 900 LoC of
`lua/psi/anthropic.lua`) and replace the ~540 LoC of curl + ~370 LoC
of pthread with 9front-native shims using native primitives:

| Linux/Haiku    | 9front replacement                |
|----------------|-----------------------------------|
| libcurl+OpenSSL| `webfs(4)` — TLS + streaming body |
| libcjson       | `libjson(2)` + hand-rolled emitter|
| pthread        | `libthread` procs + channels+alt  |
| libedit        | stub (rc/rio do line editing)     |
| ncurses        | skip; text-mode only              |
| argtable3      | `ARGBEGIN/ARGEND` in `<libc.h>`   |
| gcc+make       | `6c` + `mk`                       |
| Lua 5.4        | `lu9` — proper port               |

---

## Phase 0 — VM + ISO

`fetch-iso.sh` pulls the 9front amd64 ISO (pinned at 9front-11554;
~244 MB raw, ~233 MB gzipped). `run-vm.sh` boots it under QEMU.
9front runs cleanly under KVM (unlike Haiku where the Installer
died mid-install) — but some keyboard gotchas are worth flagging.

**Gotcha: USB keyboard doesn't come up.** 9front's kernel needs a
USB hub (message `nusb/usbd: no hubs` appears during boot). PS/2
keyboard works out of the box. Drop `-device usb-kbd`; keep
`-device usb-mouse` (wheel) but let the keyboard fall back to PS/2.

**Gotcha: VNC keyboard flaky.** After several typed commands with
shift-combinations (`!`, `*`, `&`), the rc shell's input buffer
ends up in a confused state and Enter stops reaching the shell.
Reproducible. Workaround: every couple of minutes reboot to get a
clean line editor, or type minimalistic commands and avoid
side-by-side shift combos. The **QEMU monitor `sendkey`** is more
reliable than VNC's keysym path — use `-monitor unix:/tmp/9qmon,
server,nowait` and drive input via `echo "sendkey foo" | socat -
UNIX-CONNECT:/tmp/9qmon`.

---

## Phase 1 — install

Simple text-mode installer driven through the QEMU monitor. Pick
`text` at the vgasize prompt (not the default graphical), and we
land in a rc-on-/dev/cons shell — much easier to script than rio,
and also skips the "rio: can't open display" noise.

Installer menu order: `configfs` (cwfs64x) → `partdisk` (sd00, mbr,
w then q in fdisk) → `prepdisk` (accept plan9 layout, w+q) →
`mountfs` (accept defaults, answer yes to ream) → `confignet`
(automatic / DHCP) → `mountdist` (accept) → `copydist` (accept) →
`ndbsetup` (accept hostname `cirno`) → `tzsetup` → `bootsetup`
(accept 9fat default, `yes` for Install Plan 9 MBR, `yes` for
Mark Plan 9 active) → `finish` (reboots).

After reboot, drop CD attachment, boot from disk only
(`-boot order=c`).

---

## Phase 1.5 — remote-drive the VM (auth discovery)

Two remote-access paths:

1. **`aux/listen1 tcp!*!2222 /bin/rc -li &`** on the VM exposes
   an unauthenticated TCP shell. Connect with `nc`/`printf`. The
   spawned rc runs with user `none` — can read most things but
   **cannot write** to glenda's home or /tmp (9front's /tmp is
   root:sys 755, not 1777).

2. **QEMU monitor `sendkey`** types on the VM console (which is
   logged in as glenda). Anything glenda can do, this can do — but
   typing anything with `!`/`&`/`*` eventually hangs the rc input
   parser.

The combined pattern that worked:
- glenda (via VNC) creates a world-writable dir:
  ```
  mkdir /usr/glenda/work
  chmod 1777 /usr/glenda/work
  ```
- glenda (via VNC) starts `webfs` + `aux/listen1`.
- all further work is done via `nc localhost 2222` as none
  (reading glenda's files, writing to /usr/glenda/work), and
  glenda runs build steps via hget-from-host-HTTP.

One more remote-access cul-de-sac: `auth/box /bin/rc -li` strips
`/env` from the namespace, so `${var}` expansion breaks. Not
useful for our case. Proper authenticated remote login goes via
`tcp17019` (tlssrv+rcpu) which needs drawterm on the client side —
too heavy for this project.

---

## Phase 2 — Lua 5.4 via lu9 / luix

`lu9` (GitHub mirror: github.com/okvik/luix) is a native 9front
port of Lua 5.4. Our `fetch-lu9.sh` pulls the source, then glenda
on the VM:

```
cd /usr/glenda/lu9
cd lua && mk             # builds liblua.a.6
cd ..
mk                       # builds 6.luix (standalone interpreter)
./6.luix script.lua
```

Verified: `print(1+2)` → `3`. The library `liblua.a.6` plus
`lua/shim/*.h` is what psi's embed-Lua layer needs.

**Gotcha: luix doesn't accept `-e`.** Usage is `./6.luix [-ivw]
[script] [arg ...]`. For inline eval, write to a file first.

**Gotcha: kencc warnings, not errors.** You'll see
`warning: /.../p9/base/proc.c:5 unreachable code RETURN` etc.
during `mk` — harmless, 6c is stricter about unreachable code than
gcc. Don't treat as failures.

---

## Phase 3 — webfs HTTP — real Anthropic call from 9front

**This is the headline achievement.** `9front/src/test_webfs.c` is
a ~80-line standalone C program that POSTs to
`api.anthropic.com/v1/messages` via webfs, passes the API key as
an `x-api-key` header, sends a JSON body with a tiny prompt, reads
the response body, and prints it.

Compiles with:
```
6c test_webfs.c && 6l -o test_webfs test_webfs.6
```

Runs with:
```
ANTHROPIC_API_KEY=sk-... ./test_webfs
```

**Result from a live call:**
```
conn: /mnt/web/0
{"model":"claude-haiku-4-5-20251001","id":"msg_...","type":"message",
"role":"assistant","content":[{"type":"text","text":"NINEFRONT"}],
"stop_reason":"end_turn",...}
```

That's psi's MVP signal — the model reply `"NINEFRONT"` confirming
the HTTP+JSON+TLS+auth+streaming-body path all work natively on
9front.

### webfs(4) API we actually used

Turned out simpler than Haiku's libcurl plumbing:

```
clone = open("/mnt/web/clone", ORDWR)
read(clone, numbuf, ...)                      # get N as decimal string
# Configure the request by writing attr+value lines to /mnt/web/N/ctl:
write(open("/mnt/web/N/ctl"), "url https://...\n")
write(...                   , "contenttype application/json\n")
write(...                   , "request POST\n")
write(...                   , "headers anthropic-version: 2023-06-01\n")
write(...                   , "headers x-api-key: sk-...\n")
# Body goes to its own file:
write(open("/mnt/web/N/postbody"), body, len)
# Reading body triggers the POST and streams the response bytes:
read(open("/mnt/web/N/body"), ...)
# Status code from /mnt/web/N/status ("200 OK" etc.)
```

The key was realising that **url/contenttype/request/headers all
live in `ctl`, not per-file writes**. An earlier version of the
test program tried `open("/mnt/web/N/url")` and got "url: not
implemented" — that file only exists under `parsed/` for reading
after the URL is set via ctl.

**`9front/src/http_webfs.c`** implements the signatures from
`include/psi/anthropic.h` (`psi_http_post_stream`, `psi_http_post`)
using this pattern. Ready to link into a full psi build.

---

## Phase 4 — psi9 binary: Lua + HTTP + agent, end to end

`9front/src/psi9.c` is a minimal psi runtime:
- initializes Lua 5.4 (statically linked against `lu9/lua/liblua.a.6`)
- registers `psi.http_post(url, body, headers_table)` → status,resp
  on top of our webfs shim
- registers `psi.getenv(name)` for API key lookup
- embeds a ~30-line bootstrap Lua that defines
  `psi.agent_turn(prompt)` — builds the Anthropic request JSON
  (with a tiny json-escape helper), POSTs, matches the reply text
  out of the response, unescapes the common JSON escapes, returns
  it.

Command modes:
- `psi9 -a PROMPT` — one-shot agent turn; prints the reply.
- `psi9 -e LUA_EXPR` — evaluate Lua expression (useful for debug).
- `psi9 FILE` — run a Lua script.

Build via `9front/mkfile` on the guest:
```
cd /usr/glenda && mk   # produces 6.psi9 (~800 KB)
```

**Live proof** (real Anthropic call from 9front rc):
```
term% ANTHROPIC_API_KEY=sk-... ./6.psi9 -a 'Reply one word: NINEFRONT_PSI_WORKS'
NINEFRONT_PSI_WORKS

term% ./6.psi9 -a 'What OS are you on? One short sentence.'
I don't run on a specific operating system; I'm a cloud-based AI
model hosted on Anthropic's servers.
```

That's e2e: Plan 9 rc → native C binary → Lua layer → webfs HTTPS
POST → Anthropic Messages API → model reply back on stdout.

## Phase 5 — what's left to reach parity with haiku/

psi9 is about 7 KB of C + 30 lines of Lua; full psi on Linux/Haiku
is ~1 MB of C + 4 KB of Lua. To converge:

- Replace the regex body-extractor with libjson: 9front has
  `<json.h>` — swap the `resp:match` in the boot Lua for a proper
  `psi.json.parse` binding backed by libjson.
- Unicode-aware JSON unescape in Lua (`\uXXXX` sequences).
- Pull in the real `lua/boot.lua` + `lua/psi/*.lua` with a zlib-
  compressed embed via `scripts/embed_lua.c`. 9front has zlib via
  libflate, so that compiles cleanly under 6c.
- Session persistence (JSONL) via fopen/fwrite (plain POSIX-style
  file I/O works under libc on 9front).
- `--session=FILE` flag.
- Tool-call dispatch — more involved, needs `rfork`-based process
  spawning to replace the pthread-backed pool.

None of these are *hard* — every hard piece (Lua C API, TLS,
streaming body, JSON, process identity) is already proven here.

---

## Phase 99 — what's checked in

```
9front/
├── README.md              — user-facing summary
├── JOURNEY.md             — this file
├── fetch-iso.sh           — pin + download 9front ISO
├── run-vm.sh              — QEMU driver (env: VM_ACCEL, VM_DISPLAY, VM_RES, …)
├── mkfile                 — build on the guest with `mk`
├── disk.qcow2             — generated, gitignored
├── downloads/             — generated, gitignored
└── src/
    ├── psi9.c             — the MVP binary: Lua + HTTP + agent_turn
    ├── http_webfs.c       — HTTP POST via webfs (psi_http_post etc.)
    └── test_webfs.c       — standalone webfs smoke test
```

---

## Phase 6 — hybrid port (feature parity with Haiku)

The MVP in Phase 4 was a ~7 KB standalone binary that reimplemented
just enough of psi to POST to Anthropic. Actual parity meant running
**the real upstream psi** on 9front, not a bespoke replacement.

### Strategy

Compile as much upstream `src/` + upstream Lua 5.4.6 as possible
under `pcc` (9front's APE POSIX compiler), supply thin shims for
the non-portable pieces, and link it all into one `psi` binary.

- Skipped `lu9` (shim.h conflicts with pcc).
- Vanilla upstream Lua 5.4.6 builds cleanly under pcc with
  `-D_POSIX_SOURCE -D_BSD_EXTENSION`.
- All upstream psi core files (`abort.c`, `common.c`, `session.c`,
  `agent.c`, `process.c`, `print_mode.c`, `cli.c`, `main.c`,
  `lua/vm.c`) compile unchanged under pcc.
- argtable3 compiles with `-DARG_REPLACE_GETOPT=1` once we stub
  `<err.h>` (4-line shim: `warnx` + `errx`).
- cJSON compiles cleanly; replaces the hand-rolled Phase 4 JSON.
- libcurl → rewritten `http_webfs.c` (APE-POSIX `open`/`read`/
  `write` on `/mnt/web/N/*`).
- pthread → `http_async_stub.c`: synchronous buffered chunks. No
  background thread; the agent blocks the UI loop for the duration
  of the stream. Matches the `psi.sched` contract exactly.
- libedit → `editline_stub.c`: fgets-based `readline`/`add_history`.
  Good enough for rio; not interactive under rc.
- ncurses TUI → `tui_stub.c`: returns an error from `--tui`.
- `psi_embedded_lua_table`/`psi_embedded_docs_table` → empty
  sentinel tables; psi falls back to `lua/` on disk.

### Gotchas hit along the way

**Shell-quoting noise.** `rc` parses `NAME=value` as assignment and
trips on `-DARG_REPLACE_GETOPT=0` as a bare token — quote the whole
flag. Same for `$status` interpolation: use `echo 'done='^$status`
not `echo "done=$status"`. Streaming rc one-liners through `nc |`
is a foot-gun; always stage a `.rc` file first.

**Plan 9 APE types aren't LP64 on amd64.** `sizeof(void*) = 8` but
`sizeof(size_t) = 4`, while `sizeof(ptrdiff_t) = 8`. Lua 5.4.6's
`lstrlib.c get_onecapture` returns a `size_t`-typed `CAP_POSITION`
(`-2`), which round-trips through `size_t` as `0xFFFFFFFE`,
sign-extends back into `ptrdiff_t` as `+0xFFFFFFFE`, and makes the
caller's `l != CAP_POSITION` check fire incorrectly — followed by
`lua_pushlstring` with a ~4 GB length, which raises
`memory allocation error: block too big`. Any position capture
(`s:match("()/...")`) hits this; since `session.save()` uses one
in `ensure_parent_dir`, `--session=FILE` was initially dead on
arrival. Fix: change the return type of `get_onecapture` to
`ptrdiff_t`. Patch at `9front/patches/lua-5.4.6-lstrlib-ptrdiff.patch`.

**9front `webfs(4)` has no `/status` file.** Unlike Plan-9-from-
Bell-Labs' webfs, 9front surfaces HTTP status only via the errno
string returned when `open(/mnt/web/N/body)` fails (2xx opens,
4xx/5xx returns `"500 Internal Server Error"` or similar in
errstr). `http_webfs.c` now returns 200 on successful body open
and parses the leading integer from `strerror(errno)` on failure.

**TCP shell on :2222 runs as `none`, which lacks `/mnt/web` in
its namespace.** Early builds ran pcc via the TCP channel and
wrote .o files successfully, but any command needing webfs had to
run as glenda. The `tools/9ctl` job-queue protocol bootstraps a
persistent glenda-side `worker.rc` once via VNC; after that, every
command goes through 9P file drops (`work/q/NNN.rc` + `NNN.go`
flag) and file reads (`NNN.out`), with no further keystroke
injection — millisecond round-trips instead of VNC-OCR delays.

### End-to-end verification

```
% ./9ctl job -f agent.rc
HELLO

% ./9ctl job -f multi-turn.rc
# turn 1: "My name is Ben. Remember that."
Got it, Ben — I'll remember that for the rest of our conversation.
# turn 2: "What is my name?"
Your name is Ben.
# session file:
5 /usr/glenda/work/sess9.jsonl

% ./9ctl job -f system-prompt.rc
Plan9
```

Streaming SSE works; `--session` persists across invocations;
model probe correctly reports the guest OS. The only tool that
doesn't work out of the box is `bash` (Plan 9 has no bash and
`process.c` hardcodes `/bin/sh -lc`) — a 2-line diff away from
working under rc.

### What's checked in (updated)

```
9front/
├── mkfile                      — pcc build (hybrid port)
├── patches/
│   └── lua-5.4.6-lstrlib-ptrdiff.patch  — position-capture fix
├── src/
│   ├── http_webfs.c            — libcurl replacement on webfs(4)
│   ├── http_async_stub.c       — pthread-free sync "async" stream
│   ├── editline_stub.c         — libedit fallback (fgets)
│   ├── tui_stub.c              — --tui returns unsupported
│   ├── embedded_lua_stub.c     — empty embed tables
│   └── stubs/
│       ├── editline/readline.h
│       └── err.h               — tiny <err.h> for argtable3
└── tools/
    └── 9ctl                    — host↔VM control (Python CLI)
```

---

## Phase 7 — protocol upgrade: drawterm/rcpu over keystroke injection

The hybrid port worked, but driving the VM was fragile:

- **VNC keystroke injection** mistypes special chars: `!` → `1`, `&` → `?`,
  `:` dropped, `>` → `.`, uppercase failures. Both vncdotool and QEMU
  `sendkey` have this — different keymap layers but same root cause.
- **TCP listen1 → rc as `none`** wedges after high-output commands
  (linker errors, big builds) and silently accepts new connections
  without echoing.
- **9P/exportfs** is reliable for file moves but doesn't help with
  command exec.

The Plan-9-native answer is **rcpu(1)** — TLS-authenticated remote
shell using dp9ik. Equivalent of `ssh user@host CMD` but namespace-
aware. Set up once, then everything is a real TTY and the keymap
gymnastics disappear.

### Bootstrap

`9front/tools/fullup.rc` does the one-time setup, fetched via `hget`:

1. `aux/listen1 -t 'tcp!*!2222'  /bin/rc &` — keep the old shell
   for backward compatibility while we transition.
2. `aux/listen1 -t 'tcp!*!17019' /bin/exportfs -r /usr/glenda &` —
   9P stays.
3. `auth/keyfs -p $home/lib/keys` + `auth/changeuser -p glenda` —
   set glenda's dp9ik password (fed via `hget` from a host-side
   `_pw` file written once).
4. `auth/factotum -n` + `key proto=dp9ik dom=9front user=glenda
   !password=...` written to `/mnt/factotum/ctl`.
5. `webfs -s web` — re-start webfs with `/srv/web` posted so sessions
   spawned in fresh namespaces (rcpu sessions are one such) can
   mount `/mnt/web`. Without this, psi from rcpu can't reach
   Anthropic.
6. `aux/listen1 -t 'tcp!*!17020' /rc/bin/service/tcp17019 &` —
   the rcpu service. We use 17020 (not the canonical 17019) since
   17019 already serves our exportfs.

### Host side

`9front/tools/drawterm-cmd` wraps `drawterm -G -h tcp!HOST!17020 -u
glenda -c CMD` with `expect` to feed the dp9ik password from
`$HOME/.config/psi9-pw` to drawterm's two prompts (its local-factotum
prompt and the server-side dp9ik prompt). Ergonomics: `drawterm-cmd
'rc command'` Just Works, no keystroke injection.

### Two namespace gotchas

1. **Default $PATH is sparse.** `drawterm -c CMD` doesn't source
   profile, so glenda's `bin/rc` and `bin/$objtype` aren't in PATH.
   Use absolute paths or prefix `. $home/lib/profile;`.
2. **Each rcpu session gets a fresh namespace.** Anything mounted in
   rio (webfs, networks, etc.) isn't visible. The fix is to post via
   `/srv` so any namespace can `mount '#s/web' /mnt/web`. Done in
   `fullup.rc` for webfs.

### Tradeoffs

drawterm-cmd has ~1.5s startup (TLS handshake + auth) per
invocation, vs ~50ms for the 9P/listen1 path. For batch builds and
for psi runs that already take a few seconds end-to-end, that's a
non-issue. For tiny round-trips (read one file, list a dir) keep
using `9ctl read` over 9P — faster, no auth.

Both channels stay; `9ctl` remains the right tool for files,
`drawterm-cmd` for commands.

---

## Phase 8 — interactive shell + UX fixes

After running real psi sessions through drawterm and reading the
JSONL transcripts, three problems surfaced — two real bugs and one
ergonomics nit. All three are now fixed in tree.

### Bug 1: shell tool silently failed (status=127)

Every `bash` tool call returned `{status:127, ok:false, output:""}`.
Cause: `src/core/process.c` did `execl("/bin/sh", "sh", "-lc",
command)`, and Plan 9 has no `/bin/sh`. Fix: fall through to
`execl("/bin/rc", "rc", "-c", command)` after the sh attempt fails.
Two-line change, no impact on Linux/Haiku.

### Bug 2: ANSI codes rendered as literals over rcpu

`psi.ansi.autodetect()` checked `os.getenv("sysname")`, which is
only set by `/lib/profile`. Drawterm's `-c CMD` doesn't source
profile, so on rcpu sessions ANSI stayed on and rendered as
`§[36m·§[0m` literals. Fix: detect Plan 9 by testing for
`/dev/sysname` existence — always present on Plan 9, absent on
Linux/Haiku. One conditional in `lua/psi/ansi.lua`.

### Ergo: rio doesn't auto-scroll on output

Rio terminals default to "view stays where you left it"; long psi
output sticks at the top instead of following the cursor. The
per-window control is `echo scroll > /dev/wctl`. Wired in two places
inside `fullup.rc`:

1. The `psi` wrapper does `if(test -f /dev/wctl) echo scroll
   > /dev/wctl` before exec'ing the binary.
2. Glenda's `lib/profile` gets the same line appended once. Future
   rio terms get auto-scroll for free.

The `test -f` guard matters: rcpu sessions don't have `/dev/wctl`
in their namespace (it's a per-rio-window file), and a bare `>`
errors with `mounted directory forbids creation: '/dev/wctl'` —
which actually crashes drawterm during profile sourcing.

### drawterm-shell: interactive sibling of drawterm-cmd

`drawterm-cmd` runs one command then exits — fine for scripted ops.
For interactive `ssh-into-the-VM` work, `9front/tools/drawterm-shell`
spawns drawterm without `-c`, feeds the dp9ik password through both
prompts via expect, then `interact`s the TTY over to the user. After
auth it auto-mounts `#s/web` so webfs is available immediately.

`expect` gotcha: rc's `>[2]/dev/null` redirect contains square
brackets, which Tcl interprets as command substitution. Escape:
`>\[2\]/dev/null`.

### Tooling cleanup pass

`9ctl` shed the VNC-keystroke subcommands (`run`, `type`, `ask`) and
the worker-queue (`job`) flow. They were Phase-7-era bridges that
drawterm-cmd now subsumes. Final surface: `read | ls | put | puts |
exec | screenshot` — 213 lines.

### Final tool surface

```
9front/tools/
├── fullup.rc       — guest one-time bootstrap (idempotent re-run)
├── 9ctl            — host file ops via 9P (read/ls/put/puts) + TCP
│                     rc-as-none (exec) + VNC capture (screenshot)
├── drawterm-cmd    — host: run one command on the guest
└── drawterm-shell  — host: interactive rc shell on the guest
```

Setup once, on the host:

```
echo 'mypass' > ~/.config/psi9-pw && chmod 600 ~/.config/psi9-pw
cp ~/.config/psi9-pw /tmp/9host/_pw && chmod 644 /tmp/9host/_pw
```

In rio, on the guest, after first VM boot:

```
hget http://10.0.2.2:8765/fullup.rc | rc
```

After that, normal day-to-day work is `drawterm-shell` for
interactive driving and `drawterm-cmd 'rc command'` for batched
operations. No more keystroke injection.
