# Full AmigaOS system run

This path is for running `psi` inside a full Amiga emulator with a real
Workbench/AmigaShell environment. It is separate from `amigaos/run-psi.sh`,
which uses `vamos` and does not boot a complete Amiga.

## Open-Source AROS Mode

You can boot with FS-UAE's open-source AROS Kickstart replacement:

```sh
./amigaos/full-system/run-fsuae.sh --aros
```

To run it behind VNC:

```sh
./amigaos/full-system/run-vnc.sh --aros
```

Then connect from your machine:

```sh
vncviewer localhost:5901
```

By default the VNC server binds to localhost only. Override the display,
port, or password with:

```sh
PSI_AMIGA_VNC_PORT=5902 \
PSI_AMIGA_VNC_PASSWORD=secret \
./amigaos/full-system/run-vnc.sh --aros
```

This writes `kickstart_file = internal` into the generated FS-UAE config.
FS-UAE documents this as its built-in AROS replacement ROM path. It is
legal and open-source, but less compatible than original Kickstart.

If FS-UAE stops at a boot screen, provide an AROS/Amiga boot disk or
hardfile too:

```sh
AMIGA_WORKBENCH_ADF=/path/to/aros-or-amiga-boot.adf \
./amigaos/full-system/run-fsuae.sh --aros
```

or:

```sh
AMIGA_HARDFILE=/path/to/aros68k.hdf \
./amigaos/full-system/run-fsuae.sh --aros
```

## Licensed AmigaOS Mode

You need your own licensed Amiga system media:

- Kickstart ROM, usually Amiga 1200 / Kickstart 3.1 or 3.2
- Workbench / AmigaOS install media or an existing bootable hardfile

The repo cannot provide those files.

## First run

From the repo root:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix build --impure ./amigaos#psi-amigaos

AMIGA_KICKSTART_ROM=/path/to/kick31.rom \
AMIGA_WORKBENCH_ADF=/path/to/Workbench3.1.adf \
./amigaos/full-system/run-fsuae.sh
```

This starts FS-UAE with:

- `dh0:` mapped to `amigaos/full-system/shared`
- `bridge:` mapped to `amigaos/full-system/shared/bridge`
- `psi` copied to `dh0:psi`
- host HTTPS bridge helper running on the host and serving `bridge:`

Inside Workbench, open an AmigaShell and run:

```text
cd dh0:
psi --version
psi --eval "1 + 2 * 3"
psi --agent "Say exactly: ok" --max-tokens 64
```

## Networking

The full-system launcher uses a shared-folder HTTP bridge instead of a
guest TCP/IP stack. The m68k `psi` binary writes request files to
`bridge:` or `dh0:bridge`, and `psi-amiga-http-bridge` performs the HTTPS
request on the host with `ANTHROPIC_API_KEY`.

The launcher loads `.env.local` automatically when `ANTHROPIC_API_KEY`
is not already in the environment:

```sh
./amigaos/full-system/run-fsuae.sh --aros
```

The same bridge path can be tested without booting a full Amiga:

```sh
./amigaos/run-psi.sh --agent "Say exactly: ok" --max-tokens 64
```

Current Amiga toolcalling supports `read`, `write`, `edit`, and `lua`.
Unix shell-backed tools (`bash`, `grep`, `find`, `ls`) are hidden in the
Amiga shim because AROS/AmigaOS does not provide the host POSIX shell.
The next step for those is an AmigaDOS-native process backend.

For real guest TCP/IP, install Roadshow/MiamiDX inside Workbench and add
a `bsdsocket.library` + AmiSSL transport to `psi`.

## Useful paths

- Shared Amiga directory: `amigaos/full-system/shared`
- Bridge directory: `amigaos/full-system/shared/bridge`
- Generated FS-UAE config: `amigaos/full-system/generated/psi.fs-uae`
- Optional hardfile path: set `AMIGA_HARDFILE=/path/to/workbench.hdf`
