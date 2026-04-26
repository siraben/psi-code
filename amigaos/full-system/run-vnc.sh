#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
display="${PSI_AMIGA_VNC_DISPLAY:-:99}"
geometry="${PSI_AMIGA_VNC_GEOMETRY:-1280x720x24}"
rfb_port="${PSI_AMIGA_VNC_PORT:-5901}"
rfb_password="${PSI_AMIGA_VNC_PASSWORD:-}"
localhost_only="${PSI_AMIGA_VNC_LOCALHOST:-1}"

cleanup() {
  if [ -n "${fsuae_pid:-}" ]; then kill "$fsuae_pid" 2>/dev/null || true; fi
  if [ -n "${vnc_pid:-}" ]; then kill "$vnc_pid" 2>/dev/null || true; fi
  if [ -n "${xvfb_pid:-}" ]; then kill "$xvfb_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
usage: amigaos/full-system/run-vnc.sh [run-fsuae args...]

Starts:
  Xvfb on PSI_AMIGA_VNC_DISPLAY, default :99
  x0vncserver on localhost:PSI_AMIGA_VNC_PORT, default 5901
  amigaos/full-system/run-fsuae.sh with DISPLAY set to the Xvfb display

Common:
  ./amigaos/full-system/run-vnc.sh --aros

Connect:
  vncviewer localhost:5901

Optional password:
  PSI_AMIGA_VNC_PASSWORD=secret ./amigaos/full-system/run-vnc.sh --aros
  PSI_AMIGA_VNC_LOCALHOST=0 ./amigaos/full-system/run-vnc.sh --aros
EOF
  exit 0
fi

if ! command -v Xvfb >/dev/null 2>&1; then
  echo "Xvfb is required" >&2
  exit 2
fi

if ! command -v x0vncserver >/dev/null 2>&1; then
  echo "x0vncserver is required" >&2
  exit 2
fi

Xvfb "$display" -screen 0 "$geometry" >/tmp/psi-amiga-xvfb.log 2>&1 &
xvfb_pid=$!
sleep 1

vnc_args=(-display "$display" -rfbport "$rfb_port" -SecurityTypes None)
if [ "$localhost_only" = "1" ]; then
  vnc_args+=(-localhost)
else
  vnc_args+=(-localhost no)
fi

if [ -n "$rfb_password" ]; then
  passfile="$(mktemp)"
  printf '%s\n' "$rfb_password" | vncpasswd -f > "$passfile"
  vnc_args=(-display "$display" -rfbport "$rfb_port" -PasswordFile "$passfile")
  if [ "$localhost_only" = "1" ]; then
    vnc_args+=(-localhost)
  else
    vnc_args+=(-localhost no)
  fi
fi

x0vncserver "${vnc_args[@]}" >/tmp/psi-amiga-vnc.log 2>&1 &
vnc_pid=$!
sleep 1

if [ "$localhost_only" = "1" ]; then
  echo "VNC is listening on localhost:$rfb_port"
  echo "Connect with: vncviewer localhost:$rfb_port"
else
  echo "VNC is listening on 0.0.0.0:$rfb_port"
  echo "Connect with: vncviewer <this-host>:$rfb_port"
fi
echo "FS-UAE display: $display"

DISPLAY="$display" "$root/amigaos/full-system/run-fsuae.sh" "$@" &
fsuae_pid=$!
wait "$fsuae_pid"
