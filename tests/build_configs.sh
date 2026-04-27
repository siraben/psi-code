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
      done
    done
  done
done
