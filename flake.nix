{
  description = "psi coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    chibi-src = {
      url = "github:ashinn/chibi-scheme";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, chibi-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        chibi = pkgs.stdenv.mkDerivation rec {
          pname = "chibi-scheme";
          version = "git";
          src = chibi-src;

          nativeBuildInputs = [
            pkgs.gnumake
          ];

          buildPhase = ''
            make PREFIX=$out
          '';

          installPhase = ''
            make PREFIX=$out install
          '';
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
            chibi
            pkgs.cjson
            pkgs.readline
            pkgs.ncurses
          ];

          makeFlags = [
            "PREFIX=$(out)"
            "CC=${pkgs.stdenv.cc.targetPrefix}cc"
            "PKG_CONFIG=${pkgs.pkg-config}/bin/pkg-config"
            "SCHEME_BOOT_FILE=$(out)/share/psi/boot.scm"
          ];

          installPhase = ''
            make PREFIX=$out install
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.gnumake
            pkgs.pkg-config
            pkgs.clang
            pkgs.cjson
            pkgs.gdb
            pkgs.readline
            pkgs.ncurses
            chibi
          ];

          shellHook = ''
            export PSI_SCHEME_BOOT_FILE="$PWD/scheme/boot.scm"
          '';
        };
      });
}
