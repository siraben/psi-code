#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for tui in 0 1; do
  for ansi in 0 1; do
    for color in 0 1; do
      for editline in 0 1; do
        build_dir="build-configs/tui${tui}-ansi${ansi}-color${color}-editline${editline}"
        echo "==> TUI=${tui} ANSI=${ansi} COLOR=${color} REPL_EDITLINE=${editline}"
        "${MAKE:-make}" -C "$root" \
          BUILD_DIR="$build_dir" \
          TUI="$tui" \
          ANSI="$ansi" \
          COLOR="$color" \
          REPL_EDITLINE="$editline"
        expected_tui=$tui
        if [ "$ansi" = 0 ]; then
          expected_tui=0
        fi
        expected_color=$color
        if [ "$ansi" = 0 ]; then
          expected_color=0
        fi
        actual=$("$root/$build_dir/psi" --eval 'local i=psi.runtime_info(); return tostring(i.tui).."|"..tostring(i.ansi).."|"..tostring(i.color)')
        expected="$([ "$expected_tui" = 1 ] && printf true || printf false)|$([ "$ansi" = 1 ] && printf true || printf false)|$([ "$expected_color" = 1 ] && printf true || printf false)"
        if [ "$actual" != "$expected" ]; then
          echo "feature gate mismatch: expected $expected, got $actual" >&2
          exit 1
        fi
      done
    done
  done
done
