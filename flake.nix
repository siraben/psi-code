{
  description = "psi coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Cosmopolitan cross-compiler set (siraben/cosmopkgs). Provides:
    #   - pkgs.cosmocc (4.x)
    #   - pkgsCosmo       — single-arch cross stdenv (host's native arch)
    #   - pkgsCosmoFat    — fat APE cross stdenv (x86_64 + aarch64)
    #   - pkgsCosmoAarch64
    nixpkgs-cosmo.url = "github:siraben/nixpkgs/siraben/cosmopkgs";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixpkgs-cosmo, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        cosmoBase = import nixpkgs-cosmo { inherit system; };

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
        mkPsi = { p, static ? false, extraMakeFlags ? [], extraNativeBuildInputs ? [] }: p.stdenv.mkDerivation {
          pname = if static then "psi-static" else "psi";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [
            p.gnumake
            p.pkg-config
          ] ++ extraNativeBuildInputs;

          buildInputs = [
            p.argtable
            p.cjson
            p.curl
            p.libedit
            p.lua5_4
            p.zlib
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
            runHook preInstall
            make "''${makeFlagsArray[@]}" PREFIX=$out install
            runHook postInstall
          '';

          # Keep the binary stripped only for dynamic builds. For
          # static/musl builds we want to preserve debug symbols so
          # the resulting ELF can be inspected with gdb on any host.
          dontStrip = static;
        };
      in {
        packages.default = mkPsi { p = pkgs; };
        packages.psi-gcc = self.packages.${system}.default;
        packages.psi-clang = mkPsi {
          p = pkgs;
          extraNativeBuildInputs = [ pkgs.clang ];
          extraMakeFlags = [ "CC=clang" ];
        };
        packages.psi-tcc = mkPsi {
          p = pkgs;
          extraNativeBuildInputs = [ pkgs.gcc pkgs.tinycc ];
          extraMakeFlags = [ "CC=tcc" "HOST_CC=cc" "RPATH_LDFLAGS=$(LOCAL_RPATH_LDFLAGS)" ];
        };

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

        # Cosmocc smoke tests — confirm we can produce static no-glibc
        # binaries via the cosmopkgs branch's cross stdenvs. These build
        # off `pkgsCosmo.callPackage` (single-arch) and
        # `pkgsCosmoFat.callPackage` (fat APE — one binary that runs
        # natively on x86_64 + aarch64). Mirrors the working
        # `pkgsCosmo.hello` build matrix on the cosmopkgs branch.
        #
        # No nativeBuildInputs other than the stdenv, so we don't pull
        # cross-glibc-nolibgcc through pkg-config (which is what stalled
        # the full psi build earlier).

        # Single-arch APE — host's native arch. Our cosmocc.nix uses
        # `$CC` from the stdenv, which inside pkgsCosmo is a
        # cosmocc-wrapped gcc.
        packages.psi-cosmocc-hello =
          cosmoBase.pkgsCosmo.callPackage ./nix/cosmocc.nix {};

        # Fat APE — one binary covering both x86_64 and aarch64.
        packages.psi-cosmocc-hello-fat =
          cosmoBase.pkgsCosmoFat.callPackage ./nix/cosmocc.nix {};

        # Real psi build via the cosmocc cross stdenv. TUI / libedit
        # are compiled out (cosmopolitan can't satisfy ncurses and
        # libedit's static termios init), curl is statically linked
        # for HTTPS, and the binary is a static APE.
        #
        # cosmopkgs's cross overlays apply `staticOnly = true` to
        # `lua` but not the `lua5_4` attribute, so we re-apply it
        # here. cosmocc only supports static linkage, and lua's
        # default Makefile builds liblua.so unless told otherwise.
        packages.psi-cosmocc =
          cosmoBase.pkgsCosmo.callPackage ./nix/psi-cosmocc.nix {
            lua5_4 = cosmoBase.pkgsCosmo.lua5_4.override {
              staticOnly = true;
            };
            buildCC = pkgs.stdenv.cc;
            buildZlib = pkgs.zlib;
          };

        packages.psi-cosmocc-fat =
          cosmoBase.pkgsCosmoFat.callPackage ./nix/psi-cosmocc.nix {
            lua5_4 = cosmoBase.pkgsCosmoFat.lua5_4.override {
              staticOnly = true;
            };
            # cosmocc-aarch64's runtime doesn't provide
            # __stack_chk_guard. Disable both the nixpkgs hardening
            # arm AND cjson's own CMakeLists "custom compiler flags"
            # arm (which independently adds -fstack-protector for
            # gcc builds). Skip the test suite too — it's built as
            # part of `make all`.
            cjson = cosmoBase.pkgsCosmoFat.cjson.overrideAttrs (old: {
              hardeningDisable = (old.hardeningDisable or [])
                ++ [ "stackprotector" ];
              cmakeFlags = (old.cmakeFlags or []) ++ [
                "-DENABLE_CJSON_TEST=OFF"
                "-DENABLE_CUSTOM_COMPILER_FLAGS=OFF"
              ];
            });
            buildCC = pkgs.stdenv.cc;
            buildZlib = pkgs.zlib;
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
          meta.description = "Run psi's valgrind harness";
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
          meta.description = "Run psi C static analysis";
        };

        # `nix run .#lint` — run Lua formatting/lint checks and the C
        # static-analysis target.
        apps.lint = let
          script = pkgs.writeShellApplication {
            name = "psi-lint";
            runtimeInputs = [
              pkgs.gnumake
              pkgs.pkg-config
              pkgs.cppcheck
              pkgs.gcc
              pkgs.stylua
              pkgs.lua54Packages.luacheck
              pkgs.argtable
              pkgs.cjson
              pkgs.curl
              pkgs.libedit
              pkgs.lua5_4
            ];
            text = ''
              set -eu
              cd "''${PSI_SRC:-$PWD}"
              echo "=== stylua ==="
              stylua --check lua
              echo "=== luacheck ==="
              luacheck lua
              echo "=== c analyze ==="
              make analyze
            '';
          };
        in {
          type = "app";
          program = "${script}/bin/psi-lint";
          meta.description = "Run psi Lua and C lint checks";
        };

        # `nix run .#cc-diversity` — build the same source with GCC,
        # Clang, and TinyCC. Uses separate build directories so the
        # compilers do not overwrite one another's objects.
        apps.cc-diversity = let
          script = pkgs.writeShellApplication {
            name = "psi-cc-diversity";
            runtimeInputs = [
              pkgs.gnumake
              pkgs.pkg-config
              pkgs.gcc
              pkgs.clang
              pkgs.tinycc
              pkgs.argtable
              pkgs.cjson
              pkgs.curl
              pkgs.libedit
              pkgs.lua5_4
              pkgs.zlib
            ];
            text = ''
              set -eu
              cd "''${PSI_SRC:-$PWD}"
              rm -rf build-gcc build-clang build-tcc
              make BUILD_DIR=build-gcc CC=gcc
              make BUILD_DIR=build-clang CC=clang
              make BUILD_DIR=build-tcc CC=tcc HOST_CC=cc "RPATH_LDFLAGS=\$(LOCAL_RPATH_LDFLAGS)"
            '';
          };
        in {
          type = "app";
          program = "${script}/bin/psi-cc-diversity";
          meta.description = "Build psi with GCC, Clang, and TinyCC";
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
            pkgs.tinycc
            pkgs.valgrind
          ];

          shellHook = ''
            export PSI_LUA_BOOT_FILE="$PWD/lua/boot.lua"
          '';
        };
      });
}
