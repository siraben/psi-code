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
