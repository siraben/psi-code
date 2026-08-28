# Dependency audit policy

`psi` audits runtime dependencies separately from build-time dependencies.

Runtime findings affect release decisions because those libraries ship in the
final `psi` closure. Build-time findings are tracked for builder and CI hygiene,
but they do not block a runtime release unless the vulnerable build tool
processes untrusted input or affects build integrity.

## Running the audit

Generate runtime SBOMs and fail on unwhitelisted high or critical runtime findings:

```sh
nix run .#audit-sbom
```

The app writes CycloneDX, SPDX, CSV, no-heuristic-CPE, vulnerability, and triage
artifacts under `sbom/`. These generated artifacts are ignored by git. Keep
durable audit policy in `docs/dependency-audit.md` and
`sbom/vulnxscan.whitelist.csv`, and publish full SBOM output as CI or release
artifacts when needed.

The triage report queries Repology. CI sets `PSI_SBOM_TRIAGE=0` because that
external service can be unavailable; CI still generates both runtime SBOMs,
scans vulnerabilities, and fails on unwhitelisted high or critical findings.
Local audits keep triage enabled by default.

To include the build-time closure:

```sh
PSI_SBOM_BUILDTIME=1 nix run .#audit-sbom
```

To scan another package output:

```sh
nix run .#audit-sbom -- .#psi-static
```

## Current decisions

- The default curl build contains only the HTTP client features `psi` needs.
  The default Nix packages disable brotli, zstd, HTTP/2, HTTP/3, IDN,
  PSL/cookies, SCP, GSSAPI, and OpenSSL in the mbedTLS curl build.
- `CVE-2008-6393` for package `psi` is whitelisted as a false positive. It
  refers to the unrelated `psi-im:psi` project and disappears when SBOM
  heuristic CPE matching is disabled.
- The root nixpkgs input was advanced to a curl 8.22.0 release to address the
  new September 2026 curl findings. Older accepted-risk entries remain in the
  whitelist for historical context and can be removed separately.
- Dynamic Linux builds include `glibc`. Known `glibc` scanner findings are
  whitelisted with NixOS tracker or nixpkgs issue references, so CI records them
  as accepted risk while still failing on new untracked high or critical runtime
  findings.
- Static/musl outputs link against a psi-specific static Lua build whose default
  module paths are relative instead of Nix store paths, so Lua build metadata
  does not enter the final runtime closure.
- `.#psi-static` is the preferred release artifact when avoiding dynamic
  `glibc` runtime exposure is the priority. It must still be scanned before
  release because it has a different runtime closure and risk profile.
- `CVE-2026-16554` concerns a 32-bit `size_t` overflow in cJSON. Psi's Nix
  targets are x86_64 and aarch64, so the affected integer-width path cannot
  occur in the audited runtime closure. Reassess this exception if a 32-bit
  target is added.
