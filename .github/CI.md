# GitHub CI

`workflows/ci.yml` runs the Nix-based checks on pull requests, pushes to `master`,
and manual dispatches. All jobs use `actions/setup` to install Nix and enable the
public `siraben` and `nix-community` Cachix caches alongside `cache.nixos.org`.
The `siraben` cache includes the custom LLVM toolchain used by Infer.

To upload newly built Nix packages and dependencies, configure a Cachix write
token for `siraben` as the repository secret `CACHIX_AUTH_TOKEN`:

```sh
gh secret set CACHIX_AUTH_TOKEN --repo siraben/psi-code
```

Enter the token at the prompt. The Cachix action uploads packages as they are
built. With no token (including fork pull requests), jobs only download from
the public caches. An uncached package still needs one successful build before
later jobs can reuse it.
