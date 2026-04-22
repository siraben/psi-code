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
        # Accepts:
        #   - native pkgs                                  (x86_64 dynamic)
        #   - pkgs.pkgsi686Linux                           (i686 dynamic)
        #   - pkgs.pkgsStatic                              (x86_64 static, musl)
        #   - pkgs.pkgsi686Linux.pkgsStatic                (i686 static, musl)
        # The C sources are ILP32-safe and pkg-config drives dependency
        # discovery, so every variant compiles from the same Makefile.
        #
        # `static` toggles pkg-config --static and adds -static to
        # LDFLAGS. Works cleanly only on musl-based pkgsStatic because
        # glibc cannot be fully statically linked in general (NSS
        # modules, dlopen).
        mkPsi = { p, static ? false, extraMakeFlags ? [] }: p.stdenv.mkDerivation {
          pname = if static then "psi-static" else "psi";
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
          ]
          ++ (if static then [ "STATIC=1" ] else [])
          ++ extraMakeFlags;

          # pkgsStatic sometimes misses transitive static libs at link
          # time (curl pulls zlib/openssl/nghttp2/brotli/...); include
          # them explicitly so pkg-config --static --libs resolves.
          # Most are picked up by pkg-config; we just need their .pc
          # files visible, which buildInputs already arranges.

          installPhase = ''
            make PREFIX=$out install
          '';

          # Keep the binary stripped only for dynamic builds. For
          # static/musl builds we want to preserve debug symbols so
          # the resulting ELF can be inspected with gdb on any host.
          dontStrip = static;
        };
      in {
        packages.default = mkPsi { p = pkgs; };

        # 32-bit x86 build. Requires the host to have 32-bit compat
        # libraries available (multilib). On x86_64-linux, nixpkgs
        # exposes pkgs.pkgsi686Linux that produces ILP32 ELF
        # binaries using the same kernel ABI — no qemu needed to run.
        packages.psi-i686 =
          if (pkgs.stdenv.hostPlatform.system == "x86_64-linux")
          then mkPsi { p = pkgs.pkgsi686Linux; }
          else throw "packages.psi-i686 requires x86_64-linux host (got ${pkgs.stdenv.hostPlatform.system})";

        # Fully static 64-bit binary, musl-based. The output is a
        # single self-contained ELF with no ld.so dependency — copy
        # it to any x86_64 Linux host and run it.
        packages.psi-static = mkPsi { p = pkgs.pkgsStatic; static = true; };

        # Fully static 32-bit binary, musl-based. x86_64-linux host
        # only (pkgsi686Linux is not defined elsewhere).
        packages.psi-static-i686 =
          if (pkgs.stdenv.hostPlatform.system == "x86_64-linux")
          then mkPsi { p = pkgs.pkgsi686Linux.pkgsStatic; static = true; }
          else throw "packages.psi-static-i686 requires x86_64-linux host (got ${pkgs.stdenv.hostPlatform.system})";

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

        # `nix run .#analyze` — run cppcheck + gcc -fanalyzer in the
        # source tree. Exits non-zero on any cppcheck finding (after
        # suppressions in .cppcheck-suppressions) or compiler warning.
        apps.analyze = let
          script = pkgs.writeShellApplication {
            name = "psi-analyze";
            runtimeInputs = [
              pkgs.gnumake
              pkgs.pkg-config
              pkgs.cppcheck
              pkgs.gcc
              pkgs.argtable
              pkgs.cjson
              pkgs.curl
              pkgs.libedit
              pkgs.lua5_4
              pkgs.ncurses
            ];
            text = ''
              set -eu
              cd "''${PSI_SRC:-$PWD}"
              echo "=== cppcheck ==="
              make analyze-cppcheck
              echo "=== gcc -fanalyzer ==="
              make analyze-gcc
            '';
          };
        in {
          type = "app";
          program = "${script}/bin/psi-analyze";
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
