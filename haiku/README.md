# psi on Haiku

This directory contains the Haiku R1/beta5 x86_64 port harness used to boot a
Haiku VM, build psi natively inside it, and run end-to-end smoke tests.

The scripts are restored from the Haiku port work:

- `05e1f7d` added the first end-to-end Haiku VM flow.
- `57b2746` raised the default VM display mode to 1920x1080 and seeds the
  matching VESA setting in the guest.

Those commits lived outside `origin/master`, so the port artifacts did not land
with the main branch history. This directory revives them as tracked project
files.

## Host prerequisites

- `qemu-system-x86_64`, `qemu-img`
- `mkisofs` or `genisoimage`
- `curl`
- `rsync`
- `ssh`, `scp`
- an `ANTHROPIC_API_KEY` in `.env.local` when building a guest CD that should
  run provider smoke tests

Generated files are ignored by git:

- `haiku/downloads/`
- `haiku/guest.iso`
- `haiku/guest/stage/`
- `haiku/disk.qcow2`

## Persistent VM flow

```sh
cd haiku
./fetch-iso.sh
./fetch-argtable3.sh
./build-guest-cd.sh
qemu-img create -f qcow2 disk.qcow2 32G
```

Then follow the phased 32 GB install notes:

```sh
./install-32g.sh
```

The short version:

1. Boot the anyboot ISO plus `guest.iso` with `run-vm-persist.sh`.
2. Use the Haiku Installer to create the BFS disk.
3. Run `sh /PSIGUEST/go` in the live-CD terminal to fix the bootloader and seed
   guest helpers.
4. Boot from disk and run `sh /PSIGUEST/go` again to start SSH.
5. Drive the psi dependency install and native build over SSH.

`run-vm-persist.sh` defaults to VNC on `localhost:5900`, forwards guest SSH to
host port `2222`, and advertises `1920x1080` to Haiku through QEMU stdvga. Set
`HAIKU_RES=2560x1440` or another `WxH` value to test another mode.

## Quick live-CD flow

For a shorter non-persistent experiment:

```sh
cd haiku
./fetch-iso.sh
./fetch-argtable3.sh
./build-guest-cd.sh
./run-vm-live.sh
```

Inside Haiku:

```sh
sh /PSIGUEST/go
```

The live-CD path is useful for quick boot and packaging checks. The persistent
disk path is the documented end-to-end flow for a reusable VM.

## Files

```text
haiku/
├── fetch-iso.sh             download and verify Haiku R1/beta5 anyboot ISO
├── fetch-argtable3.sh       download the pinned argtable3 amalgamation
├── build-guest-cd.sh        package psi sources, env, and helpers into guest.iso
├── run-vm-persist.sh        main persistent-disk VM entry point
├── run-vm-live.sh           live-CD-only VM entry point
├── run-vm-disk-only.sh      boot an installed disk without CDs
├── install-32g.sh           phased instructions for the real Installer path
├── sync-psi.sh              push local source changes into a running VM
├── guest/                   scripts run from the PSIGUEST CD
├── guest-runtime/           older live-CD build helpers kept for reference
└── JOURNEY.md               detailed porting notes and failure history
```

## Notes

- The Haiku Makefile path is not the normal Linux path. The guest scripts drive
  `gcc` directly where Haiku package layout requires it.
- HaikuPorts does not package argtable3, so `fetch-argtable3.sh` downloads the
  pinned single-file release and verifies its hashes.
- `guest-runtime/` records the earlier live-CD workaround path, including the
  hand-built curl notes. The persistent flow uses the active scripts under
  `guest/`.
