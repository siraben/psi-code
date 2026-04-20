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
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "psi";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [
            pkgs.gnumake
            pkgs.pkg-config
          ];

          buildInputs = [
            pkgs.argtable
            pkgs.cjson
            pkgs.curl
            pkgs.libedit
            pkgs.lua5_4
            pkgs.ncurses
          ];

          makeFlags = [
            "PREFIX=$(out)"
            "CC=${pkgs.stdenv.cc.targetPrefix}cc"
            "PKG_CONFIG=${pkgs.pkg-config}/bin/pkg-config"
            "LUA_BOOT_FILE=$(out)/share/psi/boot.lua"
          ];

          installPhase = ''
            make PREFIX=$out install
          '';
        };

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
