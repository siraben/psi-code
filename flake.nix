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

        curlWithMbedtls = p: (p.curl.override {
          opensslSupport = false;
          http3Support = false; # mbedTLS does not support curl's QUIC backend.
          scpSupport = false;   # libssh2 pulls OpenSSL back into the closure.
          gssSupport = false;   # Kerberos pulls OpenSSL back into the closure.
        }).overrideAttrs (old: {
          configureFlags = p.lib.remove "--without-ssl" old.configureFlags
            ++ [
              "--with-mbedtls=${p.lib.getDev p.mbedtls}"
              "--with-ca-bundle=${p.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
          propagatedBuildInputs = old.propagatedBuildInputs ++ [ p.mbedtls p.cacert ];
          nativeCheckInputs = p.lib.remove p.openssl (old.nativeCheckInputs or []);
        });
        curl = curlWithMbedtls pkgs;

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
        mkPsi = { p, static ? false, extraMakeFlags ? [], extraNativeBuildInputs ? [] }:
          let
            # When cross-compiling, embed_lua (the host helper that bakes
            # Lua/doc files into a .c) must run on the build machine, so
            # HOST_CC and the zlib it links against must come from the
            # outer (native) pkgs — not the cross/target package set.
            # We also use the outer pkg-config + gnumake unconditionally
            # so that pkgsCross.* and pkgsStatic don't accidentally pull
            # in target-arch tools that can't run on the build host.
            isCross = p.stdenv.buildPlatform != p.stdenv.hostPlatform;
            hostCC = "${pkgs.stdenv.cc}/bin/cc";
            curlMbedtls = curlWithMbedtls p;
          in p.stdenv.mkDerivation {
          pname = if static then "psi-static" else "psi";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [
            pkgs.gnumake
            pkgs.pkg-config
          ] ++ p.lib.optionals isCross [
            # embed_lua.c #includes <zlib.h> and links -lz at host build
            # time. Native zlib in nativeBuildInputs propagates headers
            # and libs through NIX_CFLAGS_COMPILE_FOR_BUILD / LDFLAGS.
            pkgs.zlib
          ] ++ extraNativeBuildInputs;

          buildInputs = [
            p.argtable
            p.cjson
            curlMbedtls
            p.libedit
            p.lua5_4
            p.zlib
          ];

          makeFlags = [
            "CC=${p.stdenv.cc.targetPrefix}cc"
            "HOST_CC=${hostCC}"
            "PKG_CONFIG=pkg-config"
            "LUA_BOOT_FILE=$(out)/share/psi/boot.lua"
          ]
          ++ (if static then [ "STATIC=1" ] else [])
          ++ extraMakeFlags;

          installFlags = [
            "PREFIX=$(out)"
          ];

          # Cross builds: target pkg-config returns target-arch zlib
          # flags, which break the build-host helper. Hardcode paths to
          # the build-host's zlib via makeFlagsArray (it preserves
          # spaces in a single value, unlike the makeFlags string list).
          preBuild = p.lib.optionalString isCross ''
            makeFlagsArray+=(
              "HOST_CFLAGS_ZLIB=-I${pkgs.zlib.dev}/include"
              "HOST_LIBS_ZLIB=-L${pkgs.zlib.out}/lib -lz"
            )
          '';

          # pkgsStatic sometimes misses transitive static libs at link
          # time (curl pulls zlib/mbedtls/nghttp2/brotli/...); include
          # them explicitly so pkg-config --static --libs resolves.
          # Most are picked up by pkg-config; we just need their .pc
          # files visible, which buildInputs already arranges.

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

        # Fully static RISC-V 64-bit binary, musl-based. Cross-compiled
        # via pkgsCross.riscv64-musl + pkgsStatic — the resulting ELF
        # is a single self-contained rv64gc/lp64d image with no ld.so.
        # Run it on a RISC-V Linux host or via qemu-user.
        packages.psi-static-riscv64 =
          mkPsi { p = pkgs.pkgsCross.riscv64-musl.pkgsStatic; static = true; };

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
              curl
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
              curl
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
              curl
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
            pkgs.fd
            curl
            pkgs.gdb
            pkgs.libedit
            pkgs.lua5_4
            pkgs.lua54Packages.luacheck
            pkgs.python3
            pkgs.ripgrep
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
