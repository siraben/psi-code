#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${PSI_AMIGA_OUT:-"$root/amigaos/result"}"
shared="${PSI_AMIGA_SHARED:-"$root/amigaos/full-system/shared"}"
bridge_dir="${PSI_AMIGA_BRIDGE_DIR:-"$shared/bridge"}"
generated="${PSI_AMIGA_GENERATED:-"$root/amigaos/full-system/generated"}"
config="$generated/psi.fs-uae"
use_aros=0
launch=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --aros)
      use_aros=1
      shift
      ;;
    --no-launch)
      launch=0
      shift
      ;;
    -h|--help)
      cat <<'EOF'
usage: amigaos/full-system/run-fsuae.sh [--aros] [--no-launch]

Environment:
  AMIGA_KICKSTART_ROM=/path/to/kick.rom      required unless --aros
  AMIGA_WORKBENCH_ADF=/path/to/workbench.adf optional boot floppy
  AMIGA_HARDFILE=/path/to/workbench.hdf      optional boot hardfile
  PSI_AMIGA_OUT=/path/to/psi-amigaos         optional built output
  PSI_AMIGA_SHARED=/path/to/shared-dir       optional dh0: directory
  PSI_AMIGA_BRIDGE_DIR=/path/to/bridge-dir   optional bridge: directory

--aros uses FS-UAE's internal AROS Kickstart replacement. It is open
source, but less compatible than original Kickstart/Workbench.
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ "$use_aros" -eq 0 ]; then
  if [ -z "${AMIGA_KICKSTART_ROM:-}" ]; then
    echo "AMIGA_KICKSTART_ROM is required, e.g. /path/to/kick31.rom; use --aros for FS-UAE's open-source replacement ROM" >&2
    exit 2
  fi

  if [ ! -f "$AMIGA_KICKSTART_ROM" ]; then
    echo "Kickstart ROM not found: $AMIGA_KICKSTART_ROM" >&2
    exit 2
  fi
fi

if [ "$use_aros" -eq 0 ] && [ -z "${AMIGA_WORKBENCH_ADF:-}" ] && [ -z "${AMIGA_HARDFILE:-}" ]; then
  echo "Set AMIGA_WORKBENCH_ADF=/path/to/Workbench.adf or AMIGA_HARDFILE=/path/to/Workbench.hdf" >&2
  exit 2
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -f "$root/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$root/.env.local"
  set +a
fi

mkdir -p "$shared" "$bridge_dir" "$generated"

if [ ! -x "$out/bin/psi" ] || [ ! -x "$out/bin/psi-amiga-http-bridge" ]; then
  NIXPKGS_ALLOW_UNFREE=1 nix build --impure "$root/amigaos#psi-amigaos" --out-link "$out"
fi

if [ ! -x "$out/bin/psi-amiga-http-bridge" ]; then
  echo "Missing host bridge helper in $out; rebuild failed or output is stale" >&2
  exit 1
fi

rm -f "$shared/psi" "$shared/psi-amiga-http-bridge"
if [ -x "$out/bin/psi-fsuae" ]; then
  cp "$out/bin/psi-fsuae" "$shared/psi"
else
  cp "$out/bin/psi" "$shared/psi"
fi
chmod 755 "$shared/psi"
cp "$out/bin/psi-amiga-http-bridge" "$shared/psi-amiga-http-bridge"
chmod 755 "$shared/psi-amiga-http-bridge"

rm -f "$bridge_dir"/req-* 2>/dev/null || true
pkill -f "psi-amiga-http-bridge $bridge_dir" 2>/dev/null || true

cat > "$config" <<EOF
[fs-uae]
amiga_model = A4000/040
chip_memory = 2048
fast_memory = 8192
zorro_iii_memory = 65536
hard_drive_0 = $shared
hard_drive_0_label = dh0
hard_drive_1 = $bridge_dir
hard_drive_1_label = bridge
EOF

if [ "$use_aros" -eq 1 ]; then
  cat >> "$config" <<'EOF'
kickstart_file = internal
EOF
else
  cat >> "$config" <<EOF
kickstart_file = $AMIGA_KICKSTART_ROM
EOF
fi

if [ -n "${AMIGA_HARDFILE:-}" ]; then
  if [ ! -f "$AMIGA_HARDFILE" ]; then
    echo "Hardfile not found: $AMIGA_HARDFILE" >&2
    exit 2
  fi
  cat >> "$config" <<EOF
hard_drive_2 = $AMIGA_HARDFILE
hard_drive_2_label = system
EOF
fi

if [ -n "${AMIGA_WORKBENCH_ADF:-}" ]; then
  if [ ! -f "$AMIGA_WORKBENCH_ADF" ]; then
    echo "Workbench ADF not found: $AMIGA_WORKBENCH_ADF" >&2
    exit 2
  fi
  cat >> "$config" <<EOF
floppy_drive_0 = $AMIGA_WORKBENCH_ADF
EOF
fi

echo "Generated $config"
echo "Shared folder mounted as dh0: contains $(ls -1 "$shared" | tr '\n' ' ')"
echo "Bridge folder mounted as bridge: and served by psi-amiga-http-bridge."
echo "Inside AmigaShell run: dh0:psi --agent \"Say exactly: ok\" --max-tokens 64"
if [ "$use_aros" -eq 1 ]; then
  echo "Using FS-UAE internal AROS Kickstart replacement."
  echo "If it stops at a boot screen, add an AROS/Amiga boot disk via AMIGA_WORKBENCH_ADF or AMIGA_HARDFILE."
fi

if [ "$launch" -eq 0 ]; then
  exit 0
fi

env ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
  "$out/bin/psi-amiga-http-bridge" "$bridge_dir" \
  >"$bridge_dir/bridge.log" 2>&1 &
bridge_pid=$!
trap 'kill "$bridge_pid" 2>/dev/null || true' EXIT

exec nix run --impure nixpkgs#fsuae -- "$config"
