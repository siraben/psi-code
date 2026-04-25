# psi on Haiku

Boot Haiku R1/beta5 in QEMU, build psi natively inside it, have the
Anthropic API key pre-baked into the guest environment.

## Prereqs on the host

- `qemu-system-x86_64`, `qemu-img`
- `mkisofs` or `genisoimage` (for the guest CD)
- `curl` (for the ISO download)

## One-shot

```
cd haiku
./fetch-iso.sh        # downloads Haiku anyboot ISO (~900 MB) if missing
./build-guest-cd.sh   # packs psi source + key + build script into guest.iso
./run-vm.sh           # boots Haiku in QEMU with both CDs attached
```

Inside the Haiku desktop that comes up:

1. Double-click the `guest` CD on the desktop.
2. Right-click the desktop -> Open Terminal.
3. Run `/GuestCD/setup.sh` — copies sources to `/boot/home/psi`, writes
   the API key into the login profile, installs devel packages, builds,
   runs `./build/psi --help` to confirm.

(`GuestCD` is a placeholder — Haiku mounts CDs under `/GuestCD` or
whatever the volume label is. `build-guest-cd.sh` sets the label to
`PSIGUEST` so the mount is predictable.)

## What "embed the key into the OS" means here

The key is written to `/boot/home/config/settings/profile` — Haiku's
per-user login shell profile. Every Terminal launched under the
default user thereafter inherits `ANTHROPIC_API_KEY` from the
environment. If you install Haiku to the virtual disk the profile
persists; in live-CD mode it persists only for the VM session.

## Filesystem layout on host

```
haiku/
├── README.md
├── fetch-iso.sh
├── build-guest-cd.sh
├── run-vm.sh
├── downloads/
│   └── haiku-r1beta5-x86_64-anyboot.iso   (downloaded)
├── guest/
│   ├── setup.sh                            (runs inside Haiku)
│   └── psi-src.tar.gz                      (generated)
└── disk.qcow2                              (persistent, created on first run)
```
