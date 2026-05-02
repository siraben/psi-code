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
    filnix.url = "github:mbrock/filnix";
  };

  outputs = { self, nixpkgs, nixpkgs-cosmo, flake-utils, filnix }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        inherit (pkgs) lib;

        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "compcert" ];
        };

        cosmoBase = import nixpkgs-cosmo { inherit system; };

        # ---- curl with mbedTLS ------------------------------------------

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

        luaFor = p: p.lua5_5;
        staticLuaFor = p: p.lua5_5.override { staticOnly = true; };

        # ---- Shared dependency sets -------------------------------------

        # Target-arch libraries for building psi.  Parameterized by
        # package set so cross/static/i686 variants get the right libs.
        buildDeps = p: [
          p.argtable
          p.cjson
          (curlWithMbedtls p)
          p.libedit
          (luaFor p)
          p.zlib
        ];

        # Host-side build tools (always native, never cross).
        buildTools = [ pkgs.gnumake pkgs.pkg-config ];

        devShellHook = ''
          export PSI_LUA_BOOT_FILE="$PWD/lua/boot.lua"
        '';

        # ---- Helpers ----------------------------------------------------

        # Guard a derivation behind x86_64-linux.
        requireX86_64 = name: drv:
          if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
          then drv
          else throw "${name} requires x86_64-linux host (got ${pkgs.stdenv.hostPlatform.system})";

        # Wrap a writeShellApplication as a flake app.  Every app gets
        # the build tools + library deps so `make` can find everything
        # via pkg-config; pass additional tools in extraInputs.
        mkApp = { name, description, extraInputs ? [], text }: let
          script = pkgs.writeShellApplication {
            inherit name text;
            runtimeInputs = buildTools ++ buildDeps pkgs ++ extraInputs;
          };
        in {
          type = "app";
          program = "${script}/bin/${name}";
          meta.description = description;
        };

        # ---- Package builder --------------------------------------------
        #
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
        # LDFLAGS.  Works cleanly only on musl-based pkgsStatic because
        # glibc cannot be fully statically linked in general (NSS
        # modules, dlopen).

        mkPsi = { p, static ? false, extraMakeFlags ? [], extraNativeBuildInputs ? [], curlOverride ? null }:
          let
            # When cross-compiling, embed (the host helper that bakes
            # Lua/doc files into a .c) must run on the build machine, so
            # HOST_CC and the zlib it links against must come from the
            # outer (native) pkgs — not the cross/target package set.
            # We also use the outer pkg-config + gnumake unconditionally
            # so that pkgsCross.* and pkgsStatic don't accidentally pull
            # in target-arch tools that can't run on the build host.
            isCross = p.stdenv.buildPlatform != p.stdenv.hostPlatform;
            hostCC = "${pkgs.stdenv.cc}/bin/cc";
          in p.stdenv.mkDerivation {
          pname = if static then "psi-static" else "psi";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = buildTools
            ++ lib.optionals isCross [
              # embed.c #includes <zlib.h> and links -lz at host build
              # time.  Native zlib in nativeBuildInputs propagates headers
              # and libs through NIX_CFLAGS_COMPILE_FOR_BUILD / LDFLAGS.
              pkgs.zlib
            ]
            ++ extraNativeBuildInputs;

          buildInputs = if curlOverride != null then [
            p.argtable p.cjson curlOverride p.libedit
            # filnix's nixpkgs fork predates lua5_5; override lua5_4.
            (p.lua5_4.overrideAttrs (old: {
              version = "5.5.0";
              src = p.fetchurl {
                url = "https://www.lua.org/ftp/lua-5.5.0.tar.gz";
                hash = "sha256-V8zDK7vQBcq3W8xSREBSU1r2kXiduiuQFtXFBkDWiz0=";
              };
              makeFlags = [
                "INSTALL_TOP=$(out)"
                "INSTALL_MAN=$(out)/share/man/man1"
                "R=5.5.0" "V=5.5" "PLAT=linux"
                "CC=${p.stdenv.cc.targetPrefix}cc"
                "RANLIB=${p.stdenv.cc.targetPrefix}ranlib"
                "MYLIBS=" "LDFLAGS=-fPIC"
              ];
            }))
            p.zlib
          ] else buildDeps p;

          makeFlags = [
            "CC=${p.stdenv.cc.targetPrefix}cc"
            "HOST_CC=${hostCC}"
            "PKG_CONFIG=pkg-config"
            "CA_BUNDLE_FILE=${p.cacert}/etc/ssl/certs/ca-bundle.crt"
            "LUA_BOOT_FILE=$(out)/share/psi/boot.lua"
          ]
          ++ lib.optionals static [ "STATIC=1" ]
          ++ extraMakeFlags;

          installFlags = [ "PREFIX=$(out)" ];

          # Cross builds: target pkg-config returns target-arch zlib
          # flags, which break the build-host helper.  Hardcode paths to
          # the build-host's zlib via makeFlagsArray (it preserves
          # spaces in a single value, unlike the makeFlags string list).
          preBuild = lib.optionalString isCross ''
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

          # Keep the binary stripped only for dynamic builds.  For
          # static/musl builds we want to preserve debug symbols so
          # the resulting ELF can be inspected with gdb on any host.
          dontStrip = static;
        };

      in {

        # ---- Packages ---------------------------------------------------

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

        # CompCert (ccomp) — formally verified C compiler.  CompCert
        # targets ISO C99 (a superset of the C89 this project uses)
        # but does not support GCC warning/diagnostic flags or
        # auto-dependency generation (-MMD/-MP), so both are cleared.
        packages.psi-compcert = mkPsi {
          p = pkgs;
          extraNativeBuildInputs = [ pkgs.gcc pkgs.compcert ];
          extraMakeFlags = [ "CC=ccomp" "HOST_CC=cc" "STRICT_CFLAGS=" "DEPFLAGS=" ];
        };

        # 32-bit x86 builds.  Requires the host to have 32-bit compat
        # libraries available.  On x86_64-linux, nixpkgs exposes
        # pkgs.pkgsi686Linux that produces ILP32 ELF binaries using the
        # same kernel ABI — no qemu needed to run.
        packages.psi-i686 = requireX86_64 "packages.psi-i686"
          (mkPsi { p = pkgs.pkgsi686Linux; });

        # Fully static 64-bit binary, musl-based.  The output is a
        # single self-contained ELF with no ld.so dependency — copy it
        # to any x86_64 Linux host and run it.
        packages.psi-static = mkPsi { p = pkgs.pkgsStatic; static = true; };

        # Fully static 32-bit binary, musl-based.
        packages.psi-static-i686 = requireX86_64 "packages.psi-static-i686"
          (mkPsi { p = pkgs.pkgsi686Linux.pkgsStatic; static = true; });

        # Fully static RISC-V 64-bit binary, musl-based.  Cross-compiled
        # via pkgsCross.riscv64-musl + pkgsStatic — the resulting ELF
        # is a single self-contained rv64gc/lp64d image with no ld.so.
        # Run it on a RISC-V Linux host or via qemu-user.
        packages.psi-static-riscv64 =
          mkPsi { p = pkgs.pkgsCross.riscv64-musl.pkgsStatic; static = true; };

        # Full psi APE builds with cosmocc-specific dependency overrides.
        packages.psi-cosmocc =
          let
            p = cosmoBase.pkgsCosmo;
            mbedtlsPatched = p.mbedtls.overrideAttrs (old: {
              hardeningDisable = (old.hardeningDisable or []) ++ [ "all" ];
              env = (old.env or {}) // {
                NIX_CFLAGS_COMPILE =
                  (old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error";
              };
              # cosmocc only links static libraries.
              cmakeFlags = (old.cmakeFlags or []) ++ [
                "-DCMAKE_C_FLAGS=-Wno-error"
                "-DENABLE_TESTING=OFF"
                "-DENABLE_PROGRAMS=OFF"
                "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF"
                "-DUSE_STATIC_MBEDTLS_LIBRARY=ON"
              ];
              # Avoid nixpkgs's stale mbedTLS config.pl hook.
              postConfigure = "";
            });
            curlMbedtls = (p.curl.override {
              opensslSupport = false;
              http3Support = false;
              scpSupport = false;
              gssSupport = false;
            }).overrideAttrs (old: {
              configureFlags = p.lib.remove "--without-ssl" old.configureFlags
                ++ [ "--with-mbedtls=${p.lib.getDev mbedtlsPatched}" ];
              propagatedBuildInputs = old.propagatedBuildInputs ++ [ mbedtlsPatched ];
              nativeCheckInputs = p.lib.remove p.openssl (old.nativeCheckInputs or []);
              hardeningDisable = (old.hardeningDisable or []) ++ [ "all" ];
              env = (old.env or {}) // {
                NIX_CFLAGS_COMPILE =
                  (old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error";
              };
            });
            cjsonPatched = p.cjson.overrideAttrs (old: {
              hardeningDisable = (old.hardeningDisable or []) ++ [ "stackprotector" ];
              cmakeFlags = (old.cmakeFlags or []) ++ [
                "-DENABLE_CJSON_TEST=OFF"
                "-DENABLE_CUSTOM_COMPILER_FLAGS=OFF"
              ];
            });
          in
          p.callPackage ./nix/psi-cosmocc.nix {
            lua = staticLuaFor p;
            curl = curlMbedtls;
            cacert = p.cacert;
            cjson = cjsonPatched;
            openssl = null;
            mbedtls = mbedtlsPatched;
            buildCC = pkgs.stdenv.cc;
            buildZlib = pkgs.zlib;
          };

        packages.psi-cosmocc-fat =
          let
            p = cosmoBase.pkgsCosmoFat;
            mbedtlsPatched = p.mbedtls.overrideAttrs (old: {
              hardeningDisable = (old.hardeningDisable or []) ++ [ "all" ];
              env = (old.env or {}) // {
                NIX_CFLAGS_COMPILE =
                  (old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error";
              };
              # cosmocc only links static libraries.
              cmakeFlags = (old.cmakeFlags or []) ++ [
                "-DCMAKE_C_FLAGS=-Wno-error"
                "-DENABLE_TESTING=OFF"
                "-DENABLE_PROGRAMS=OFF"
                "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF"
                "-DUSE_STATIC_MBEDTLS_LIBRARY=ON"
              ];
              # Avoid nixpkgs's stale mbedTLS config.pl hook.
              postConfigure = "";
            });
            curlMbedtls = (p.curl.override {
              opensslSupport = false;
              http3Support = false;
              scpSupport = false;
              gssSupport = false;
            }).overrideAttrs (old: {
              configureFlags = p.lib.remove "--without-ssl" old.configureFlags
                ++ [ "--with-mbedtls=${p.lib.getDev mbedtlsPatched}" ];
              propagatedBuildInputs = old.propagatedBuildInputs ++ [ mbedtlsPatched ];
              nativeCheckInputs = p.lib.remove p.openssl (old.nativeCheckInputs or []);
              hardeningDisable = (old.hardeningDisable or []) ++ [ "all" ];
              env = (old.env or {}) // {
                NIX_CFLAGS_COMPILE =
                  (old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error";
              };
            });
            cjsonPatched = p.cjson.overrideAttrs (old: {
              hardeningDisable = (old.hardeningDisable or []) ++ [ "stackprotector" ];
              cmakeFlags = (old.cmakeFlags or []) ++ [
                "-DENABLE_CJSON_TEST=OFF"
                "-DENABLE_CUSTOM_COMPILER_FLAGS=OFF"
              ];
            });
          in
          p.callPackage ./nix/psi-cosmocc.nix {
            lua = staticLuaFor p;
            curl = curlMbedtls;
            cacert = p.cacert;
            cjson = cjsonPatched;
            openssl = null;
            mbedtls = mbedtlsPatched;
            buildCC = pkgs.stdenv.cc;
            buildZlib = pkgs.zlib;
          };

        # Memory-safe build via Fil-C (https://github.com/mbrock/filnix).
        # Fil-C compiles C to memory-safe code by treating it as a
        # cross-compilation target (x86_64-unknown-linux-gnufilc0).
        # The stock filnix curl uses openssl without a compiled-in CA
        # bundle, so we wrap the binary with SSL_CERT_FILE pointing at
        # the nixpkgs cacert bundle.
        packages.psi-filc = let
          pkgsFilc = filnix.legacyPackages.${system}.pkgsFilc;
        in (mkPsi {
          p = pkgsFilc;
          curlOverride = pkgsFilc.curl;
          extraNativeBuildInputs = [ pkgs.makeWrapper ];
        }).overrideAttrs (old: {
          postFixup = (old.postFixup or "") + ''
            wrapProgram $out/bin/psi \
              --set SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          '';
        });

        # ---- Apps -------------------------------------------------------

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

        # `nix run .#analyze` — cppcheck + gcc -fanalyzer.
        apps.analyze = mkApp {
          name = "psi-analyze";
          description = "Run psi C static analysis";
          extraInputs = [ pkgs.cppcheck pkgs.gcc ];
          text = ''
            cd "''${PSI_SRC:-$PWD}"
            echo "=== cppcheck ==="
            make analyze-cppcheck
            echo "=== gcc -fanalyzer ==="
            make analyze-gcc
          '';
        };

        # `nix run .#lint` — Lua formatting/lint + C static analysis.
        apps.lint = mkApp {
          name = "psi-lint";
          description = "Run psi Lua and C lint checks";
          extraInputs = [
            pkgs.cppcheck
            pkgs.gcc
            pkgs.stylua
            pkgs.lua54Packages.luacheck
          ];
          text = ''
            cd "''${PSI_SRC:-$PWD}"
            echo "=== stylua ==="
            stylua --check lua
            echo "=== luacheck ==="
            luacheck lua
            echo "=== c analyze ==="
            make analyze
          '';
        };

        # `nix run .#cc-diversity` — build with GCC, Clang, and TinyCC.
        apps.cc-diversity = mkApp {
          name = "psi-cc-diversity";
          description = "Build psi with GCC, Clang, and TinyCC";
          extraInputs = [ pkgs.gcc pkgs.clang pkgs.tinycc ];
          text = ''
            cd "''${PSI_SRC:-$PWD}"
            rm -rf build-gcc build-clang build-tcc
            make BUILD_DIR=build-gcc CC=gcc
            make BUILD_DIR=build-clang CC=clang
            make BUILD_DIR=build-tcc CC=tcc HOST_CC=cc "RPATH_LDFLAGS=\$(LOCAL_RPATH_LDFLAGS)"
          '';
        };

        # ---- Dev shells -------------------------------------------------

        devShells.compcert = pkgs.mkShell {
          packages = buildTools ++ buildDeps pkgs ++ [
            pkgs.compcert
            pkgs.gcc
          ];
          shellHook = devShellHook;
        };

        devShells.default = pkgs.mkShell {
          packages = buildTools ++ buildDeps pkgs ++ [
            pkgs.clang
            pkgs.clang-tools
            pkgs.cppcheck
            pkgs.fd
            pkgs.gdb
            pkgs.lua54Packages.luacheck
            (pkgs.python3.withPackages (ps: [
              ps.pexpect
              ps.pyte
              ps.pytest
            ]))
            pkgs.ripgrep
            pkgs.stylua
            pkgs.tinycc
            pkgs.valgrind
          ];
          shellHook = devShellHook;
        };
      });
}
