# psi on 9front

A hybrid-port of `psi` (Claude coding agent) to **9front** (Plan 9
derivative), sibling of the `haiku/` port in this repo.

## What works

- `psi --agent=TEXT` end-to-end: streaming SSE, tool dispatch,
  cJSON records.
- `psi --session=FILE`: multi-turn JSONL persistence.
- `psi --print`, `--eval`, `--version`, `--system-prompt`.
- Full Lua agent runtime (all 23 `lua/psi/*.lua` modules).
- HTTPS via 9front's `webfs(4)`. No curl, no OpenSSL.

## What doesn't

- `--tui` (ncurses) — returns a clear unsupported error.
- The `bash` tool — Plan 9 has no bash and `process.c` currently
  hardcodes `/bin/sh -lc`. A follow-up patch should route to
  `/bin/rc -c` on 9front.
- Interactive REPL — `readline` is a fgets-based stub.

## The shape of the port

The agent turn loop (~900 LoC of `lua/psi/anthropic.lua`) is
OS-agnostic and ships unchanged. Only the C scaffolding gets
replaced. Upstream `src/core/*.c` + `src/lua/vm.c` + cJSON +
argtable3 + Lua 5.4.6 all compile under `pcc` (9front's APE POSIX
compiler) with tiny shims for the non-portable pieces.

| Linux/Haiku needs    | 9front replacement                   |
|----------------------|--------------------------------------|
| `libcurl` + OpenSSL  | `http_webfs.c` on `/mnt/web/...`     |
| `pthread` + cond var | `http_async_stub.c` (sync buffered)  |
| `libedit` readline   | `editline_stub.c` (fgets fallback)   |
| `ncurses` TUI        | `tui_stub.c` (returns unsupported)   |
| `<err.h>` (argtable) | 4-line shim (`warnx`/`errx`)         |
| `gcc` + `make`       | `pcc` + `mk`                         |
| Lua 5.4              | upstream 5.4.6 + ptrdiff patch       |

See `patches/lua-5.4.6-lstrlib-ptrdiff.patch` — one-liner fix for a
Lua position-capture bug that only surfaces on 32-bit-`size_t` /
64-bit-`ptrdiff_t` systems like 9front APE on amd64.

## One-time host setup

    cd 9front
    ./fetch-iso.sh                  # downloads current 9front ISO
    qemu-img create -f qcow2 disk.qcow2 32G
    VM_ATTACH_ISO=1 VM_BOOT_ORDER=d bash run-vm.sh
    # VNC-drive the installer per JOURNEY.md. Reboot when done.

## Normal boot

    bash run-vm.sh                  # KVM, disk-only, VNC :0

## Host↔VM control

Two host-side channels, both over forwarded TCP:

- **`tools/9ctl`** — fast file ops (read/ls/put) over 9P/exportfs
  on port 17019. Runs as user `glenda`. ~10ms round-trip.
- **`tools/drawterm-cmd`** — TLS-authenticated remote shell via
  `rcpu(1)` on port 17020, bootstrapped by `tools/fullup.rc` on the
  guest (one-time, sets up `auth/keyfs` + `factotum` + `webfs -s web`
  + the rcpu listener). The Plan-9-native equivalent of `ssh user@host
  CMD`. ~1.5s startup but no keystroke-injection mistypes, no
  shift-key gotchas, no listen1-as-`none` namespace wedges.

Examples:

    ./tools/drawterm-cmd 'rc command'
    ./tools/drawterm-cmd < script.rc
    ./tools/9ctl read work/psi-link.log

Setup once:

    # Host: stash a dp9ik password where drawterm-cmd reads it
    echo 'mypass' > ~/.config/psi9-pw && chmod 600 ~/.config/psi9-pw
    cp ~/.config/psi9-pw /tmp/9host/_pw && chmod 644 /tmp/9host/_pw

    # Guest (in rio term, after first boot):
    hget http://10.0.2.2:8765/fullup.rc > /tmp/up.rc; rc /tmp/up.rc

See `JOURNEY.md` Phase 7 for the protocol-upgrade story.
