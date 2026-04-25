# psi on 9front

A hybrid-port of `psi` (Claude coding agent) to **9front** (a Plan 9
derivative), sibling of the `haiku/` port in this repo.

## The shape of the port

`psi`'s agent turn loop (≈900 LoC) lives in
`lua/psi/anthropic.lua` and is OS-agnostic. Only ~540 LoC of C
libcurl plumbing and ~370 LoC of pthread glue are Linux/Haiku-
specific. We replace just those pieces:

| Linux/Haiku needs    | 9front replacement                   |
|----------------------|--------------------------------------|
| `libcurl` + OpenSSL  | `webfs(4)` via `/mnt/web/...`        |
| `libcjson`           | `libjson` (parse) + hand-rolled emit |
| `pthread` + cond var | `libthread` procs + Channels + alt   |
| `libedit` readline   | stub (rc/rio handle line editing)    |
| `ncurses` TUI        | skipped for MVP                      |
| `argtable3`          | `ARGBEGIN/ARGEND` in `<libc.h>`      |
| `gcc` + `make`       | `pcc`/`6c` + `mk`                    |
| Lua 5.4              | `lu9` port (github.com/okvik/luix)    |

Everything under `lua/` and most of `src/core/` compile as-is.

## One-time host setup

    cd 9front
    ./fetch-iso.sh                  # downloads current 9front ISO
    qemu-img create -f qcow2 disk.qcow2 32G
    VM_ATTACH_ISO=1 VM_BOOT_ORDER=d bash run-vm.sh
    # VNC-drive the installer per JOURNEY.md. Reboot when done.

## Normal boot

    bash run-vm.sh                  # KVM, disk-only, VNC :0

## Ship a build

    bash sync-psi.sh                # tars source, hgets into VM,
                                    # runs install-psi.rc which
                                    # does mk + install to /bin.

## Verify

    # Inside VM or via 9P export to host:
    psi --agent 'Say exactly one word: OK'   # → OK
    psi --version                            # → 0.1.0

See `JOURNEY.md` for every wall hit along the way.
