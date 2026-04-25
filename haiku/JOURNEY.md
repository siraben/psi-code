# Haiku port attempt — session journey

A narrative of every wall we hit and every way around it, written while
still in the VM. The repo has the scripts under `haiku/`; this file
explains *why* each one exists.

---

## Starting point

The ask: run psi inside 9front (Plan 9). Short answer: psi can't run
on Plan 9 without a real port (libcurl/libedit/ncurses/pthread all
missing; Plan 9 has no Linux ABI shim). Pivoted to Haiku — same goal,
POSIX-ish userland, modern OpenSSL, native `pkgman` with a large
HaikuPorts repo.

## Phase 0 — infrastructure

`haiku/fetch-iso.sh`, `haiku/build-guest-cd.sh`, `haiku/run-vm.sh`,
`haiku/run-vm-live.sh`. Downloads `haiku-r1beta5-x86_64-anyboot.iso`,
packs psi + argtable3 amalgamation + API key into a second CD (labeled
`PSIGUEST`), launches QEMU with both CDs plus a 16 GB qcow2.

Tooling discovery: host is headless (no DISPLAY). All VM interaction
has to go over VNC, so `run-vm.sh` selects `-display vnc=:0`
automatically. The Nix-shell `vncdo` package drives the desktop.

## Phase 1 — walls and workarounds

### 1. virtio-vga kernel panic

First boot: kernel debugger (KDL) instead of desktop. Stack trace:

```
PANIC: Unexpected exception "General Protection Exception" in kernel mode
Thread 125 "app_server" on CPU 0
...
virtio_gpu_send_cmd / virtio_gpu_get_display_info
notify_queue (virtio_pci)
```

Haiku's `virtio_gpu` driver GPFs talking to QEMU's virtio-vga device.
**Fix:** replace `-device virtio-vga` with plain `-vga std`. Boots
cleanly in ~40 s under KVM. All three `run-vm*.sh` scripts reflect
this.

### 2. installer crashes at package 174/464 (llvm12_libs)

`haiku-r1beta5` installer consistently errored at
`llvm12_libs-12.0.1-8-x86_64.hpkg` with "General system error" under
KVM. Reproducible across RAM sizes and clean disk state. The disk
never becomes bootable, so this blocks the "install to persistent
qcow2" path.

Temporary workaround: booted with `-machine ...,accel=tcg`, which got
past the crash, producing an installed disk. That disk then failed to
boot at splash — a second bug we never isolated. (Possibly related to
duplicate "Haiku" volumes confusing the bootloader when both CD and
disk are attached.)

We abandoned the "install to disk" path and did everything in the live
CD session.

### 3. vncdo can't type underscore or shifted chars

`vncdo type "_"` sends `-`. `&&` gets dropped. Long strings also get
corrupted at low delay. Fixes:

- Pass `--force-caps` to vncdo (crucial for `_`, `$`, `|`, etc.).
- Keep delay at ~150 ms or higher.
- For anything long: serve the script from a host HTTP server
  (`python3 -m http.server 8765`) and `wget http://10.0.2.2:8765/...`
  inside the VM. 10.0.2.2 is QEMU slirp's host alias.

### 4. The `./` tar prefix black hole

First attempt: `tar czf ... .` on the host produced a tarball with
`./Makefile`, `./src/...`. Extracting on Haiku via `tar xzf` appeared
to succeed — `ls` showed the entries — but individual files gave
"cannot access 'Makefile': No such file or directory". Every file
path listed was a phantom.

**Fix:** `tar` with `--transform='s,^\./,,'` (or list members without
the dot). Entries become `Makefile`, `src/...` and suddenly the
filesystem behaves. Haiku's tar doesn't like the `./` prefix in
BFS-backed paths.

### 5. `cp` fails with "cannot lseek: Operation not supported"

Occurs when the source file lives on the packagefs- or tmpfs-backed
mounts (`/tmp`, `/PSIGUEST`). Haiku's packagefs refuses `lseek`, which
`cp` uses to preserve holes.

**Fix:** always use `cat src > dst` instead of `cp`. Several scripts
do this. Notably the first argtable3 header copy silently produced a
0-byte file, which then made psi's `cli.c` fail with "undefined type
struct arg_str". Wasted an hour on that one.

### 6. `pkgman install` wants a reboot, bricks exec()

Live CD trap: installing any `_devel` package wants to stage a
transaction that activates on reboot. On a live CD, reboot wipes the
session.

Tried `pkgman install -H` (home-level). That worked for gcc alone, but
`haiku_devel` drags in the `haiku` runtime package, which overlays a
*newer* `libroot.so` into `/boot/home/config/lib/`. That libroot
references `libgcc_s` symbol versions that don't exist in the
live-kernel ABI. Every subsequent `exec()` — `ls`, `cp`, `make`,
everything — dies in `runtime_loader` with "Cannot open file
libgcc_s.so.1". Shell builtins still work; nothing else does.

The uninstall transaction also only applies at reboot. There's no
undo without rebooting, and reboot wipes the session.

**Fix (what works):** never use `pkgman install -H` for anything. Use
`package extract -C /tmp/ext /boot/system/packages/<pkg>.hpkg` which
just lays files down — no packagefs transaction, no libroot
overlay. Point PATH, LIBRARY_PATH, C_INCLUDE_PATH, PKG_CONFIG_PATH at
`/tmp/ext/...`. `haiku/guest-runtime/build-psi.sh` does this.

Packages we extract this way:
- `gcc`, `gcc_syslibs`, `gmp`, `mpfr`, `mpc`, `binutils` — toolchain
- `haiku_devel` — POSIX/BeOS headers (posix, os, bsd, os/support, ...)
- `lua`, `lua_devel`, `cjson`, `cjson_devel`, `zlib`, `zlib_devel`,
  `libedit`, `libedit_devel`, `ncurses6`, `ncurses6_devel`,
  `curl`, `curl_devel`, `libnghttp2`, `openssh`, `tmux`.

### 7. `stdio.h` / `Errors.h` / `BeBuild.h` not found

Haiku's headers live under a dozen subtrees:
`headers/posix`, `headers/os`, `headers/os/app`,
`headers/os/support`, `headers/os/kernel`, `headers/os/interface`,
`headers/os/storage`, `headers/os/drivers`, `headers/os/locale`,
`headers/bsd`, `headers/lua54`. gcc built with `--prefix=/boot/system`
knows these paths by default; our extracted tree at `/tmp/ext` does
not.

**Fix:** enumerate every subdir and feed them as `-isystem` flags
(plus `C_INCLUDE_PATH`). `haiku/guest-runtime/mk.sh` has the full
list.

### 8. `-std=c89` vs `long long` in Haiku's stdlib.h

psi's Makefile uses `-std=c89 -Werror`. Haiku's `stdlib.h` declares
`long long llabs(long long)`, which `-std=c89` rejects. Override:
`BASE_CFLAGS='-std=gnu99 -Wall'` in `mk.sh`.

### 9. argtable3 amalgamation missing basic #includes on Haiku

`argtable3.c` expects `<limits.h>` transitively; Haiku doesn't pull it
in. Then it expects `<err.h>`/`warnx`, and Haiku's `bsd/err.h` has
prototyped K&R-style decls gcc 13 refuses to parse. Patches in the
runtime scripts:

- Prepend `#include <limits.h>` to `/tmp/argtable3.c`.
- Replace `#include <err.h>` with a local `warnx` stub using
  `vfprintf`.

### 10. ld: cannot find `crtn.o`, `-lgcc_s`, `-lroot`

Haiku's gcc compiled with `/boot/system` built-in prefix can't find
startup objects and libraries in our `/tmp/ext` tree.

**Fix:** `CC='gcc -B/tmp/ext/bin/ -B/tmp/ext/develop/lib/ -L... -L...'`
with explicit `-L` for every lib dir we care about. `mk.sh` wraps CC
like this.

### 11. libcurl ABI: OPENSSL_3.2.0 symbol missing

The `curl-8.19.0-1` hpkg in Haiku R1/beta5 references
`OPENSSL_3.2.0` versioned symbols, but the `openssl3` hpkg ships
OpenSSL 3.0.14. The packages don't actually work together on this
release. `pkgman search` reveals no `openssl_3.2.x`.

Dead end with the shipped libcurl.

### 12. libcurl: also missing `libssh2_session_set_read_timeout`

The system libcurl additionally references a libssh2 function added
in 1.11.0; Haiku ships libssh2 1.9.0. Same version-mismatch pattern.

So we can't use the shipped libcurl either way.

**Fix:** built curl 8.4.0 from source against the shipped OpenSSL
3.0.14, targeting psi's needs:
- `--with-openssl` (pointed via CPPFLAGS/LDFLAGS at /tmp/ext)
- `--with-ca-bundle=/boot/system/data/ssl/CARootCertificates.pem`
- disabled every protocol/backend psi doesn't need

Build command is in `haiku/guest-runtime/build-curl.sh`. One gotcha:
`make install` uses `install -c` which hits the `lseek` bug on
/tmp-backed BFS; we copy the built `.so` manually with `cat`.

### 13. vncdo expanding `$PATH` on the host

Using `export PATH=/tmp/ext/bin:...:$PATH` in a vncdo `type` payload
makes host bash expand `$PATH` *before* sending. The VM receives a
500-char mess of nix-store paths. Fix: single-quote outer arg, or
deliver via `wget`.

### 14. getting ssh working, without vncdo for every command

Critical quality-of-life win. Sequence:

1. `pkgman install -y openssh` → "reboot necessary" (ignored),
   then `package extract -C /tmp/ext /boot/system/packages/openssh-*.hpkg`.
2. Generated host key: `ssh-keygen -t ed25519 -N '' -f
   /boot/home/config/settings/ssh/hk_ed25519`.
3. Dropped host's public key into **both**
   `/boot/home/.ssh/authorized_keys` (the classic path) **and**
   `/boot/home/config/settings/ssh/authorized_keys` (the path Haiku's
   sshd actually honors per its built-in config —
   `AuthorizedKeysFile=config/settings/ssh/authorized_keys`).
4. Ran sshd with a config file pointing HostKey at our ed25519 key and
   listening on 2222 (matches QEMU `hostfwd=tcp::2222-:2222`).
5. Client side: `ssh -i ~/.ssh/psi_haiku -o IdentitiesOnly=yes ...`.
   Without `IdentitiesOnly`, OpenSSH offers agent-held RSA keys first,
   Haiku's sshd logs `RSA key is not allowed` and the ed25519 key
   never gets offered before MaxAuthTries kicks in.

`ps` on Haiku listed processes but `pkill` doesn't exist — had to
`ps | grep sshd` and `kill -9 <pid>` manually when iterating.

After ssh worked, everything else was `ssh user@localhost 'cmd'`
instead of vncdo typing.

### 15. Red herrings worth noting

- **"Connection reset by peer"** at ssh kex = no sshd actually
  running. Haiku's `ps` may not show child sshd; look at `ps | grep
  ssh` explicitly.
- **Printers dialog popping up** during vncdo typing — a stray click
  lands on an icon and opens an app. Close via Deskbar → right-click
  → Close.
- **Haiku /tmp is mapped to /boot/system/cache/tmp/**, so error
  messages referencing `/boot/system/cache/tmp/ext/...` are the same
  files as `/tmp/ext/...`.
- **Haiku's `libroot.so` version is tied to the running kernel**;
  bringing in any package that relies on a newer libroot without
  rebooting breaks every exec().

## Phase 2 — where we got

- psi compiled: `/var/psi/build/psi`, 256 KB, x86_64 ELF.
- Links: liblua.so.5.4, libcjson.so.1, libedit.so.0, **libcurl.so.4**
  (our custom 8.4 build with CA bundle baked in), libz.so.1,
  libncursesw.so.6, libroot.so. libargtable3 statically linked.
- CA bundle verified inside the custom libcurl via
  `strings libcurl.so.4.8.0 | grep CARoot`.
- ssh works end-to-end.

## Phase 3 — the remaining wall (resolved)

The earlier "psi hangs before printing" was live-CD-specific and tied
to the custom `/tmp/ext` toolchain + hand-rolled libcurl 8.4. Going
persistent-disk changed everything: on a disk-backed Haiku we can
`pkgman install` normally, `reboot` to activate, and build against the
**stock** HaikuPorts libcurl + openssl3 (3.5.5, past the OPENSSL_3.2
issue) + libssh2 1.11.1 (past the `libssh2_session_set_read_timeout`
issue). No custom libcurl required.

The "no output, EC=3/4" symptom turned out to be the runtime_loader
failing to resolve `libssh2_session_set_read_timeout` — SSH pipes
swallowed the stderr line "runtime_loader: …" because it was long and
the SSH client surfaced stdout. Running with `2>/tmp/err` showed it.

Once libssh2 1.11.1 was pulled in and the VM rebooted, psi runs
cleanly: `--version`, `--help`, and `--agent="…"` with a real
Anthropic API key all succeed. Verified e2e with a live call that
returned the model's response over the pipe.

## Phase 3.5 — persistent-disk via CoW (quick, ~1.4 GB BFS)

The shortcut: rather than wrestle with the Installer, we CoW the
anyboot ISO into the qcow2:

```
qemu-img create -f qcow2 \
  -b "$(pwd)/downloads/haiku-r1beta5-x86_64-anyboot.iso" -F raw \
  -o size=16G disk.qcow2
```

Boot it directly (no CD boot) and Haiku just runs from disk with the
BFS already populated. All `pkgman install` writes land on qcow2 CoW
pages and persist across reboots. `haiku/run-vm-persist.sh` does this.

Provisioning (scripted in `haiku/guest/ssh-bootstrap.sh`):
1. Boot VM; use vncdo to type one command:
   `wget -qO /tmp/ssh.sh http://10.0.2.2:8765/ssh-bootstrap.sh && bash /tmp/ssh.sh`
2. That installs openssh (already preinstalled in anyboot), writes our
   pubkey, generates a persistent ed25519 host key, and starts sshd on
   port 2222. From there, everything happens over SSH.
3. Persist sshd across reboots by dropping a `UserBootscript` in
   `/boot/home/config/settings/boot/`.

Build:
1. `pkgman install -y gcc binutils haiku_devel gcc_syslibs_devel`
   (triggers a staged haiku runtime update — `ls` still works, don't
   panic).
2. `pkgman install -y lua lua_devel cjson cjson_devel libedit_devel
   ncurses6_devel zlib_devel curl_devel openssl3_devel pkgconfig
   nghttp2 nghttp2_devel libssh2_devel` (libssh2_devel drags in
   libssh2-1.11.1 which is what we actually need).
3. `reboot` once so the new libroot + libssh2 activate.
4. Compile argtable3 by hand into `~/config/non-packaged/develop/{lib,headers}`.
5. psi has no GNU make on Haiku, so drive gcc directly — 14 object
   compilations plus a link. The Haiku-specific link flag is `-lbsd`
   (needed for argtable3's `warnx`), plus `-lnetwork` for Haiku's
   BSD socket glue.
6. `./build/psi --version` → `0.1.0`. Done.

(See "Phase 4 — what's checked in" below for the scripts.)

## Phase 3.6 — real Installer + 32 GB partition (proper install)

When you actually want a 32 GB (or larger) BFS partition and not just
the 1.4 GB that anyboot ships with, you have to run the Installer.
This is flaky on R1/beta5 — here's the exact sequence that works.

### Key findings

1. **KVM breaks the Installer**: under KVM the Installer reliably dies
   with "General system error" somewhere between packages 106/466 and
   176/466 (exact package varies — git, llvm12_libs, ncurses, …).
   Under **TCG** (slower, ~6 min for the install) it completes cleanly.
2. **Use IDE for the target disk**: `-drive if=ide,…` — virtio-blk
   seems OK too but IDE is closest to what SeaBIOS + Haiku bootloader
   expect, and lets us reuse the same qcow2 under both TCG and KVM
   without BIOS-level surprises.
3. **Never kill the VM mid-flow**: killing QEMU after the Installer
   says "Installation completed" leaves the BFS journal unsynced.
   When you mount the partition later, you see an empty filesystem
   even though the qcow2 has 720 MB of data. Click **Restart** in
   the Installer (or do a Deskbar → Shutdown from the Live-CD
   desktop) so BFS gets its clean unmount.
4. **`writembr` + `makebootable` are both needed**: the Installer
   writes the BFS stage-1 to the partition's boot block, but does
   not always update the MBR chain and its bootcode target. Without
   both, SeaBIOS hangs with `bios_ia32 stage1: Failed to load OS`.
5. **`mount -t bfs` vs `mountvolume`**: `mountvolume Haiku` mounts
   the *first* volume named "Haiku" it finds — on Live CD this is
   the CD's Haiku, not the disk's. Use an explicit
   `mount -t bfs /dev/disk/scsi/0/0/0/0 /tmp/d` so `makebootable
   /tmp/d` targets the disk.
6. **Keyboard nav beats the mouse under TCG**: vncdo clicks on
   menus race ahead of the GUI's event loop under TCG. Hover an
   item and press **Enter** instead of clicking.
7. **`openssl3_devel` alone does not upgrade `openssl3`**: the
   disk-installed Haiku r1beta5 comes with openssl3 3.0.14 from the
   base `haiku` meta-package. `pkgman install -y openssl3_devel`
   pulls in the 3.5.5 `_devel`, but the runtime library stays at
   3.0.14 and psi dies with `libssl.so.3: version "OPENSSL_3.2.0"
   not found`. Fix: explicitly `pkgman install -y openssl3` (will
   upgrade to 3.5.5-1 from HaikuPorts). Belt-and-braces: list
   `openssl3 openssl3_devel` side-by-side in the install line.

### Minimising VNC typing

VNC typing under TCG is flaky: clicks race the event loop,
`&&` gets dropped, `_` sometimes becomes `-`, long strings desync.
**Everything the user types over VNC is now the same 15-character
command:**

```
sh /PSIGUEST/go
```

`/PSIGUEST/go` is a dispatcher on the always-attached guest CD. It
detects the current state and runs the right thing:

- Live CD + disk has install  → `fix-boot.sh` (writembr, makebootable,
  seeds `/boot/home/bin/*`, seeds UserBootscript that auto-mounts
  PSIGUEST and auto-starts sshd on every future boot, then clean
  shutdown).
- Anywhere else              → start sshd, then the host drives
  the rest over ssh.

Subcommands for the host side (no VNC typing at all):

```
ssh … 'go build'       # runs install-psi.sh — with seeded /boot/home/bin
                       # on $PATH, no wget needed; same on second pass
                       # after the reboot.
ssh … 'go fix'         # explicit MBR fix
ssh … 'go ssh'         # restart sshd
```

After the first successful disk boot (with a seeded UserBootscript),
sshd and the PSIGUEST mount are automatic. The user only types over
VNC in the single "Live-CD post-install" moment. Everything else is
clicks in the GUI or `ssh` + one short word.

The PSIGUEST CD is **always attached** (see `run-vm-persist.sh`);
`HAIKU_ATTACH_ISO` controls only the 1.38 GB anyboot install ISO,
which is only needed during Phase 1/2 of the 32 GB flow.

### Scripted flow

`haiku/install-32g.sh` is the top-level driver. Split into phases
because each needs a different `run-vm-persist.sh` env combination:

```
./fetch-iso.sh
./build-guest-cd.sh
qemu-img create -f qcow2 disk.qcow2 32G       # blank, no ISO backing

# Phase 1 — TCG Installer (~6 min under Ryzen 5950X)
HAIKU_ACCEL=tcg HAIKU_ATTACH_CDS=1 HAIKU_BOOT_ORDER=d \
HAIKU_DISK_IF=ide  bash run-vm-persist.sh
# VNC-drive: Install Haiku → DriveSetup (Initialize MBR, Create
# partition, Format BFS "Haiku") → Installer (pick 32 GiB target,
# Begin). On "Installation completed", click Restart.

# Phase 2 — still Live CD, but now to fix the MBR
# (happens automatically after Restart reboots into CD). Drive to
# Terminal, then run haiku/guest/fix-boot.sh which:
#   mount -t bfs /dev/disk/scsi/0/0/0/0 /tmp/d
#   writembr  /dev/disk/scsi/0/0/0/raw
#   makebootable /tmp/d
#   sync && shutdown -q            # clean unmount

# Phase 3 — boot disk only under KVM (fast, full 8-core + 16 GB RAM)
HAIKU_DISK_IF=ide bash run-vm-persist.sh
# SSH bootstrap + psi install per Phase 3.5. Now with 32 GB BFS.
```

Build deps installed in the correct order to avoid the openssl
trap:

```
pkgman install -y gcc gcc_syslibs_devel haiku_devel binutils
pkgman install -y lua lua_devel cjson cjson_devel libedit_devel \
    ncurses6_devel zlib_devel \
    openssl3 openssl3_devel \
    curl_devel pkgconfig \
    nghttp2 nghttp2_devel libssh2_devel
reboot                        # activates the haiku runtime update
                              # AND the openssl3 3.5.5 swap
```

After this, argtable3 compile + gcc link flow is identical to
Phase 3.5. Link flags unchanged: `-lbsd -lnetwork -lpthread` plus
the pkg-config outputs.

### Runtime-loader gotcha — how to debug

If `psi --version` returns EC=4 with no visible output, it's almost
certainly `runtime_loader: … version "OPENSSL_X.Y.Z" not found` or
similar. SSH pipes eat the line at the wrap point. Capture explicitly:

```
./build/psi --version 1>/tmp/o 2>/tmp/e; echo EC=$?; cat /tmp/e
```

This is how we found the openssl3_devel-only mistake in round two.

## Phase 4 — what's checked in

Under `haiku/`:

- `README.md` — user-facing summary.
- `fetch-iso.sh`, `build-guest-cd.sh`, `run-vm.sh`, `run-vm-live.sh`,
  `run-vm-disk-only.sh` — VM management.
- `guest/setup.sh`, `guest/ssh-setup.sh`, `guest/UserBootscript` —
  in-VM provisioning helpers (superseded by `ssh-bootstrap.sh` +
  `install-psi.sh` but kept for reference).
- `fetch-argtable3.sh` — fetches the argtable3 amalgamation (~224
  KB, pinned release + SHA256) into the gitignored
  `haiku/downloads/argtable3/` cache. `build-guest-cd.sh` invokes
  it transparently.
- `guest/linux-static/` — static Linux musl psi binaries for
  reference (don't run on Haiku — different ABI).
- **Active in-VM helpers:**
  - `guest/ssh-bootstrap.sh` — one-wget bootstrap for sshd on port
    2222 with our pubkey authorised.
  - `guest/fix-boot.sh` — post-Installer MBR fix + clean shutdown
    (mount disk BFS, writembr, makebootable, shutdown).
  - `guest/install-psi.sh` — disk-booted path: installs pkgman deps
    (incl. explicit openssl3 upgrade), stages profile + Boot-
    script, then on second invocation (post-reboot) builds psi via
    direct gcc and installs it to /boot/home/bin.
- **Host-side drivers:**
  - `run-vm-persist.sh` — single boot wrapper, env-configurable
    (HAIKU_ACCEL, HAIKU_DISK_IF, HAIKU_BOOT_ORDER, HAIKU_ATTACH_CDS).
  - `install-32g.sh` — prints the full 32 GB flow with the exact
    env combinations per phase.
- `guest-runtime/` — the old live-CD approach (`build-curl.sh`,
  `mk.sh`, `build-psi.sh`, `fix-curl.sh`).  Superseded; kept for
  historical reference and because the hand-built libcurl is a
  useful data point.

Not checked in (too large / reproducible):
- `haiku/downloads/haiku-r1beta5-x86_64-anyboot.iso` — `.gitignore`d.
- `haiku/guest.iso`, `haiku/disk.qcow2` — generated.

## How to resume next session

Two paths, pick the one you need:

### Fast (1.4 GB BFS, anyboot CoW) — Phase 3.5

Use when you just want psi running; 1.4 GB is enough for psi + deps
but tight.

```
cd haiku
./fetch-iso.sh
./build-guest-cd.sh
qemu-img create -f qcow2 \
  -b "$PWD/downloads/haiku-r1beta5-x86_64-anyboot.iso" -F raw \
  -o size=16G disk.qcow2
bash run-vm-persist.sh                          # VNC :0
# Click "Try Haiku" → Terminal → type (14 chars):
#    sh /PSIGUEST/go
# Dispatcher starts sshd. Then from host:
ssh -i ~/.ssh/psi_haiku -o IdentitiesOnly=yes -p 2222 user@localhost \
    "ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY' sh /PSIGUEST/go build"
# install-psi.sh runs phase 1, asks for reboot. Reboot, re-run:
ssh … 'sh /PSIGUEST/go build'    # phase 2: compiles psi
```

### Full (32 GB BFS, real Installer) — Phase 3.6

Use when you want the full 32 GB partition. Adds ~15 min for TCG.

```
cd haiku
./fetch-iso.sh
./build-guest-cd.sh
rm -f disk.qcow2
qemu-img create -f qcow2 disk.qcow2 32G

# 1. TCG Installer. VNC-drive DriveSetup + Installer. After "Installation
#    completed", click the yellow close (NOT Restart).
HAIKU_ACCEL=tcg HAIKU_ATTACH_ISO=1 HAIKU_BOOT_ORDER=d \
  bash run-vm-persist.sh

# 2. MBR fix. Still Live-CD desktop. Terminal → type:
#       sh /PSIGUEST/go
#    The dispatcher detects Live-CD + installed disk and runs
#    fix-boot.sh (writembr + makebootable + clean shutdown).

# 3. Disk boot under KVM + psi install.
bash run-vm-persist.sh         # defaults: kvm/ide/boot=c, PSIGUEST attached
# Terminal → sh /PSIGUEST/go   (starts sshd). Then from host:
ssh … "ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY' sh /PSIGUEST/go build"
# Reboot to activate staged packages, then:
ssh … 'sh /PSIGUEST/go build'   # compiles psi
```

Total VNC typing for the 32 GB flow: **two 14-char commands**.
Everything else is clicks (Installer GUI) or ssh. Verified working
end-to-end on 32 GB disk with 8 vCPU + 16 GB RAM.

## Lessons

- Haiku live-CD development is a minefield of packagefs interactions.
  **Never** `pkgman install` without `-H`; prefer `package extract`
  unless you control reboot.
- vncdo is a last resort. Spin up sshd as early as possible.
- Tarball path prefixes matter on BFS. Never `./`.
- Haiku's own curl/libssh2/openssl are subtly version-mismatched
  across the R1/beta5 release; expect to rebuild libcurl from source
  against the shipped OpenSSL.
- Keep a running host HTTP server on 10.0.2.2:8765 the whole session;
  wget is how you reliably move scripts and small assets in.
