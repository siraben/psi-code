#!/usr/bin/env bash
# Build a flake package and, when it produces psi, run the smoke suite against it.

set -euo pipefail

: "${PACKAGE_ATTR:?PACKAGE_ATTR must name the flake package to build}"

nix_build_args=(--no-link --print-out-paths)
if [ -n "${NIX_BUILD_FLAGS:-}" ]; then
  read -r -a extra_nix_build_args <<< "$NIX_BUILD_FLAGS"
  nix_build_args+=("${extra_nix_build_args[@]}")
fi

out="$(nix build "${nix_build_args[@]}" ".#${PACKAGE_ATTR}")"
psi_bin="$out/bin/psi"

if [ ! -x "$psi_bin" ]; then
  echo "package ${PACKAGE_ATTR} built at ${out}; no psi binary to smoke-test"
  exit 0
fi

smoke_args=(--psi "$psi_bin" --no-live)
if [ -n "${SMOKE_EXCLUDES:-}" ]; then
  IFS=, read -r -a excludes <<< "$SMOKE_EXCLUDES"
  for exclude in "${excludes[@]}"; do
    smoke_args+=(--exclude "$exclude")
  done
fi

nix develop --command python3 tests/smoke.py "${smoke_args[@]}"
