#!/usr/bin/env bash
# Run inside the feature-matrix CI job. Reads MAKE_FLAGS and SMOKE_EXCLUDES
# from the environment (passed via the workflow step's `env:` block), and
# expects CI_BUILD_DIR to be set by .github/actions/setup.

set -euo pipefail

# Variables are expanded by the inner bash inside the nix shell, not here.
# shellcheck disable=SC2016
nix develop --command bash -euxo pipefail -c '
  make_args=()
  if [ -n "$MAKE_FLAGS" ]; then
    read -r -a make_args <<< "$MAKE_FLAGS"
  fi

  smoke_args=(--psi build/psi --no-live)
  if [ -n "$SMOKE_EXCLUDES" ]; then
    IFS=, read -r -a excludes <<< "$SMOKE_EXCLUDES"
    for exclude in "${excludes[@]}"; do
      smoke_args+=(--exclude "$exclude")
    done
  fi

  make BUILD_DIR="$CI_BUILD_DIR" "${make_args[@]}"
  python3 tests/smoke.py "${smoke_args[@]}"
'
