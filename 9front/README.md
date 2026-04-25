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

After install, bootstrap the job-queue worker once via VNC, then
drive everything through `tools/9ctl` (9P + TCP, no further
keystroke injection):

    ./tools/9ctl job -f path/to/cmd.rc       # submit+wait+read
    ./tools/9ctl read work/psi-link.log      # read any file via 9P
    ./tools/9ctl put build.rc psi9-build/build.rc

See `JOURNEY.md` for every wall hit along the way.
