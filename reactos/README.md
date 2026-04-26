# ReactOS VM

ReactOS is an open source Windows NT-style hobby OS. This target boots the
official ReactOS 0.4.15 release in QEMU.

```sh
./reactos/fetch-isos.sh
./reactos/build-psi.sh
./reactos/run-vm.sh
```

The default boots the LiveCD and exposes QEMU VNC on port `5902`.

For an installed VM:

```sh
./reactos/create-disk.sh
REACTOS_MODE=install ./reactos/run-vm.sh
REACTOS_MODE=disk ./reactos/run-vm.sh
```

Useful environment variables:

- `REACTOS_DISPLAY=vnc|gtk|sdl|none`
- `REACTOS_VNC=:2`
- `REACTOS_ACCEL=kvm|tcg`
- `REACTOS_MEM=1024`
- `REACTOS_SMP=2`
- `REACTOS_BRIDGE=0` disables the shared FAT drive and host HTTPS bridge

The ReactOS guest sees the shared drive as `D:` or another later drive letter.
Run `D:\psi.exe --probe-bridge`, then `D:\psi.exe --agent "Say exactly: ok"`.

TUI mode uses a full-screen Win32 console UI when run interactively from
Command Prompt. If stdin/stdout are redirected, it falls back to the scripted
line protocol used by smoke tests. Exit with `/exit` or `/quit`:

```bat
D:\psi.exe --tui
D:\run-tui.bat
```

`D:\run-tui.bat` is a smoke test that drives the TUI, lets the agent use the
write tool, and opens `D:\analog-clock.html`. Scripted TUI runs include the
same tool trace events that the interactive console TUI renders in the
transcript. The latest verified run wrote:

```text
assistant> TUI_OK
assistant>
╭─ write D:/analog-clock.html
│ written
╰─
assistant> CLOCK_DONE
```

Connect to the graphical desktop with VNC on `127.0.0.1:5902`.
