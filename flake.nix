{
  description = "psi coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        # Build the psi derivation against an arbitrary package set.
        # Accepts both the native `pkgs` and 32-bit compat sets
        # (pkgs.pkgsi686Linux) without any source changes — the C
        # sources are ILP32-safe and every dependency is looked up
        # via pkg-config from the passed-in set.
        mkPsi = p: extraMakeFlags: p.stdenv.mkDerivation {
          pname = "psi";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [
            p.gnumake
            p.pkg-config
          ];

          buildInputs = [
            p.argtable
            p.cjson
            p.curl
            p.libedit
            p.lua5_4
            p.ncurses
          ];

          makeFlags = [
            "PREFIX=$(out)"
            "CC=${p.stdenv.cc.targetPrefix}cc"
            "PKG_CONFIG=${p.pkg-config}/bin/pkg-config"
            "LUA_BOOT_FILE=$(out)/share/psi/boot.lua"
          ] ++ extraMakeFlags;

          installPhase = ''
            make PREFIX=$out install
          '';
        };
      in {
        packages.default = mkPsi pkgs [];

        # 32-bit x86 build. Requires the host to have 32-bit compat
        # libraries available (multilib). On x86_64-linux, nixpkgs
        # exposes pkgs.pkgsi686Linux that produces ILP32 ELF
        # binaries using the same kernel ABI — no qemu needed to run.
        packages.psi-i686 =
          if (pkgs.stdenv.hostPlatform.system == "x86_64-linux")
          then mkPsi pkgs.pkgsi686Linux []
          else throw "packages.psi-i686 requires x86_64-linux host (got ${pkgs.stdenv.hostPlatform.system})";

        # `nix run .#valgrind` — memcheck a non-agent exercise set.
        apps.valgrind = let
          vgScript = pkgs.writeShellApplication {
            name = "psi-valgrind";
            runtimeInputs = [
              self.packages.${system}.default
              pkgs.valgrind
              pkgs.coreutils
            ];
            text = ''
              exec ${./tests/valgrind.sh} "$@"
            '';
          };
        in {
          type = "app";
          program = "${vgScript}/bin/psi-valgrind";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.argtable
            pkgs.gnumake
            pkgs.pkg-config
            pkgs.clang
            pkgs.clang-tools
            pkgs.cppcheck
            pkgs.cjson
            pkgs.curl
            pkgs.gdb
            pkgs.libedit
            pkgs.lua5_4
            pkgs.lua54Packages.luacheck
            pkgs.stylua
            pkgs.ncurses
            pkgs.valgrind
          ];

          shellHook = ''
            export PSI_LUA_BOOT_FILE="$PWD/lua/boot.lua"
          '';
        };
      });
}
