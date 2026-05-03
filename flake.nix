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
    sirabenOverlay.url = "github:siraben/overlay";

    # ESP-IDF + Espressif's QEMU fork. Drives the firmware/ build and
    # the QEMU smoke/live tests under tests/test_esp_*.py.
    nixpkgs-esp-dev.url = "github:mirrexagon/nixpkgs-esp-dev";
  };

  outputs = { self, nixpkgs, nixpkgs-cosmo, flake-utils, filnix, sirabenOverlay,
              nixpkgs-esp-dev }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        inherit (pkgs) lib;

        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "compcert" ];
        };

        cosmoBase = import nixpkgs-cosmo { inherit system; };

        espPkgs = nixpkgs-esp-dev.packages.${system} or {};

        # Lua 5.5 source tarball used by components/lua-cmod. Fetched
        # at build time so we don't vendor Lua's source into the repo.
        luaSrc = pkgs.fetchurl {
          url = "https://www.lua.org/ftp/lua-5.5.0.tar.gz";
          hash = "sha256-V8zDK7vQBcq3W8xSREBSU1r2kXiduiuQFtXFBkDWiz0=";
        };

        # Espressif's QEMU fork. Upstream nixpkgs ships a generic
        # qemu-system-xtensa, but it lacks the ESP32-specific
        # peripheral models (WiFi simulation via openeth, eFuse,
        # cache, etc.) the firmware needs to boot. We build the
        # esp-develop branch of espressif/qemu, which adds those.
        # Lazy: built only when something forces it (apps.qemu,
        # tests/test_esp_*.py).
        espQemu = pkgs.qemu.override {
          hostCpuTargets = [ "xtensa-softmmu" ];
        };

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
        # curlPkg/luaPkg allow cross-toolchain variants (e.g. Fil-C)
        # to substitute deps that can't be built with the default
        # overrides for that package set.
        buildDeps = { p, curlPkg ? curlWithMbedtls p, luaPkg ? luaFor p }: [
          p.argtable
          p.cjson
          curlPkg
          p.libedit
          luaPkg
          p.zlib
        ];

        # Host-side build tools (always native, never cross).
        buildTools = [ pkgs.gnumake pkgs.pkg-config ];

        devShellHook = ''
          export PSI_LUA_BOOT_FILE="$PWD/lua/boot.lua"
          export HOST_CFLAGS_ZLIB="-I${pkgs.zlib.dev}/include"
          export HOST_LIBS_ZLIB="-L${pkgs.zlib.out}/lib -lz"
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
            runtimeInputs = buildTools ++ buildDeps { p = pkgs; } ++ extraInputs;
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

        mkPsi = { p, static ? false, extraMakeFlags ? [], extraNativeBuildInputs ? [],
                   deps ? buildDeps { inherit p; } }:
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

          buildInputs = deps;

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
          # filnix's nixpkgs fork predates lua5_5; override lua5_4.
          filcLua55 = pkgsFilc.lua5_4.overrideAttrs (old: {
            version = "5.5.0";
            src = pkgsFilc.fetchurl {
              url = "https://www.lua.org/ftp/lua-5.5.0.tar.gz";
              hash = "sha256-V8zDK7vQBcq3W8xSREBSU1r2kXiduiuQFtXFBkDWiz0=";
            };
            makeFlags = [
              "INSTALL_TOP=$(out)" "INSTALL_MAN=$(out)/share/man/man1"
              "R=5.5.0" "V=5.5" "PLAT=linux"
              "CC=${pkgsFilc.stdenv.cc.targetPrefix}cc"
              "RANLIB=${pkgsFilc.stdenv.cc.targetPrefix}ranlib"
              "MYLIBS=" "LDFLAGS=-fPIC"
            ];
          });
        in (mkPsi {
          p = pkgsFilc;
          # Stock filnix curl (openssl); mbedtls tests SIGTRAP under fil-c.
          # Lua 5.5 isn't in filnix's nixpkgs yet, so override lua5_4.
          deps = buildDeps {
            p = pkgsFilc;
            curlPkg = pkgsFilc.curl;
            luaPkg = filcLua55;
          };
          extraNativeBuildInputs = [ pkgs.makeWrapper ];
        }).overrideAttrs (old: {
          postFixup = (old.postFixup or "") + ''
            wrapProgram $out/bin/psi \
              --set SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          '';
        });

        # ---- ESP32 firmware ---------------------------------------------

        # Builds the ESP-IDF firmware image for `firmware/` against the
        # esp-idf-esp32 toolchain provided by nixpkgs-esp-dev. Outputs
        # the merged-flash binary at $out/psi-firmware.bin which can be
        # passed straight to qemu-system-xtensa or esptool.
        packages.firmware = if espPkgs ? esp-idf-esp32 then
          pkgs.stdenv.mkDerivation {
            pname = "psi-firmware";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [
              espPkgs.esp-idf-esp32
              pkgs.gcc
              pkgs.zlib
              pkgs.cmake
              pkgs.ninja
              pkgs.python3
            ];

            # ESP-IDF's setup_idf hook expects $IDF_TOOLS_PATH writable.
            preBuild = ''
              export HOST_CC=${pkgs.stdenv.cc}/bin/cc
              export LUA_SRC_DIR=$(mktemp -d)/lua-5.5.0/src
              tar -xzf ${luaSrc} -C $(dirname $(dirname $LUA_SRC_DIR))
              echo "Lua sources at $LUA_SRC_DIR"
            '';

            buildPhase = ''
              cd firmware
              idf.py --no-ccache build
            '';

            installPhase = ''
              mkdir -p $out
              cp build/psi_firmware.elf $out/psi.elf
              cp build/psi_firmware.bin $out/psi.bin
              cp build/partition_table/partition-table.bin $out/partition-table.bin
              cp build/bootloader/bootloader.bin $out/bootloader.bin
              # Merged image: bootloader + partition table + app, ready for QEMU.
              esptool.py --chip esp32 merge_bin -o $out/psi-firmware.bin \
                0x1000  $out/bootloader.bin \
                0x8000  $out/partition-table.bin \
                0x10000 $out/psi.bin || true
            '';

            dontStrip = true;
            meta.description = "psi firmware image for ESP32";
          }
        else
          pkgs.runCommand "psi-firmware-unavailable" {} ''
            echo "nixpkgs-esp-dev did not expose esp-idf-esp32 for ${system}; cannot build firmware" >&2
            exit 1
          '';

        # ---- Apps -------------------------------------------------------

        # `nix run .#qemu` — boot the firmware under qemu-system-xtensa
        # with user-mode networking; forwards host TCP 8000 → guest 80
        # so the SPA is reachable at http://localhost:8000. Used by
        # tests/test_esp_qemu.py and tests/test_esp_live.py.
        # NOTE: upstream nixpkgs qemu's xtensa-softmmu lacks Espressif's
        # ESP32 peripheral models (WiFi via openeth, eFuse, etc.).
        # On platforms without a working esp-qemu, this still boots far
        # enough to exercise C/Lua glue but WiFi-dependent code paths
        # will not function. Real-hardware flash via apps.flash is the
        # canonical path; QEMU is for CI/smoke only.
        apps.qemu = {
          type = "app";
          program = let
            qemuApp = pkgs.writeShellApplication {
              name = "psi-qemu";
              runtimeInputs = [ espQemu self.packages.${system}.firmware ];
              text = ''
                FW="${self.packages.${system}.firmware}/psi-firmware.bin"
                echo "psi web chat: http://localhost:8000"
                echo "firmware:    $FW"
                exec qemu-system-xtensa \
                  -nographic \
                  -machine esp32 \
                  -drive file="$FW",if=mtd,format=raw \
                  -nic user,model=open_eth,hostfwd=tcp::8000-:80 \
                  "$@"
              '';
            };
          in "${qemuApp}/bin/psi-qemu";
          meta.description = "Run psi firmware in qemu-system-xtensa";
        };

        # `nix run .#flash` — write the firmware to a connected ESP32.
        # Defaults to /dev/ttyUSB0; override via PSI_FLASH_PORT.
        apps.flash = {
          type = "app";
          program = let
            flashApp = pkgs.writeShellApplication {
              name = "psi-flash";
              runtimeInputs = (lib.optionals (espPkgs ? esp-idf-esp32) [
                espPkgs.esp-idf-esp32
              ]) ++ [ self.packages.${system}.firmware ];
              text = ''
                PORT="''${PSI_FLASH_PORT:-/dev/ttyUSB0}"
                FW="${self.packages.${system}.firmware}/psi-firmware.bin"
                echo "Flashing $FW to $PORT"
                exec esptool.py --chip esp32 --port "$PORT" --baud 460800 \
                  write_flash 0x0 "$FW"
              '';
            };
          in "${flashApp}/bin/psi-flash";
          meta.description = "Flash psi firmware to a connected ESP32";
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

        # `nix run .#scan-build` — Clang Static Analyzer.
        apps.scan-build = let
          curl = curlWithMbedtls pkgs;
          lua = luaFor pkgs;
        in mkApp {
          name = "psi-scan-build";
          description = "Run Clang Static Analyzer";
          extraInputs = [
            pkgs.clang
            pkgs.clang-tools
            pkgs.gcc
            pkgs.scan-build-py
          ];
          text = ''
            cd "''${PSI_SRC:-$PWD}"
            scan_cppflags=()
            ${lib.optionalString pkgs.stdenv.isLinux ''
              scan_cppflags+=(
                "-isystem" "$(${pkgs.gcc}/bin/gcc -print-file-name=include)"
                "-isystem" "${pkgs.glibc.dev}/include"
              )
            ''}
            make_args=(
              "BUILD_DIR=''${SCAN_BUILD_BUILD_DIR:-build-scan-build}"
              "analyze-scan-build"
              "CPPFLAGS=''${scan_cppflags[*]}"
              "PSI_CFLAGS_LUA=-I${lib.getDev lua}/include"
              "PSI_LIBS_LUA=-L${lib.getLib lua}/lib -llua"
              "PSI_CFLAGS_CJSON=-I${lib.getDev pkgs.cjson}/include -I${lib.getDev pkgs.cjson}/include/cjson"
              "PSI_CFLAGS_CURL=-I${lib.getDev curl}/include"
              "PSI_CFLAGS_ZLIB=-I${lib.getDev pkgs.zlib}/include"
              "PSI_CFLAGS_EDIT=-I${lib.getDev pkgs.libedit}/include -I${lib.getDev pkgs.libedit}/include/editline"
              "PSI_CFLAGS_ARGTABLE=-I${lib.getDev pkgs.argtable}/include"
              "HOST_CFLAGS_ZLIB=''${scan_cppflags[*]} -I${lib.getDev pkgs.zlib}/include"
              "HOST_LIBS_ZLIB=-L${lib.getLib pkgs.zlib}/lib -lz"
            )
            make "''${make_args[@]}"
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

        # `nix run .#infer` — Infer static analysis from siraben/overlay.
        apps.infer = let
          curl = curlWithMbedtls pkgs;
          lua = luaFor pkgs;
        in mkApp {
          name = "psi-infer";
          description = "Run Infer static analysis";
          extraInputs = [
            sirabenOverlay.packages.${system}.infer
            pkgs.gcc
          ];
          text = ''
            cd "''${PSI_SRC:-$PWD}"
            build_dir="''${INFER_BUILD_DIR:-/tmp/psi-infer-build}"
            results_dir="''${INFER_RESULTS_DIR:-/tmp/psi-infer-out}"
            infer_cppflags=()
            ${lib.optionalString pkgs.stdenv.isLinux ''
              infer_cppflags+=(
                "-isystem" "$(${pkgs.gcc}/bin/gcc -print-file-name=include)"
                "-isystem" "${pkgs.glibc.dev}/include"
              )
            ''}
            make_args=(
              "BUILD_DIR=$build_dir"
              "analyze-infer"
              "CPPFLAGS=''${infer_cppflags[*]}"
              "PSI_CFLAGS_LUA=-I${lib.getDev lua}/include"
              "PSI_LIBS_LUA=-L${lib.getLib lua}/lib -llua"
              "PSI_CFLAGS_CJSON=-I${lib.getDev pkgs.cjson}/include -I${lib.getDev pkgs.cjson}/include/cjson"
              "PSI_CFLAGS_CURL=-I${lib.getDev curl}/include"
              "PSI_CFLAGS_ZLIB=-I${lib.getDev pkgs.zlib}/include"
              "PSI_CFLAGS_EDIT=-I${lib.getDev pkgs.libedit}/include -I${lib.getDev pkgs.libedit}/include/editline"
              "PSI_CFLAGS_ARGTABLE=-I${lib.getDev pkgs.argtable}/include"
              "HOST_CFLAGS_ZLIB=''${infer_cppflags[*]} -I${lib.getDev pkgs.zlib}/include"
              "HOST_LIBS_ZLIB=-L${lib.getLib pkgs.zlib}/lib -lz"
            )
            rm -rf "$build_dir" "$results_dir"
            mkdir -p "$build_dir"
            infer run \
              --fail-on-issue \
              --cost \
              --print-active-checkers \
              --force-integration make \
              --results-dir "$results_dir" \
              -- make "''${make_args[@]}"
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
          packages = buildTools ++ buildDeps { p = pkgs; } ++ [
            pkgs.compcert
            pkgs.gcc
          ];
          shellHook = devShellHook;
        };

        # ESP-IDF dev shell. Brings in the toolchain, esptool, qemu,
        # and python test deps so `nix develop .#esp` lands in a
        # working firmware environment.
        devShells.esp = pkgs.mkShell {
          packages = (lib.optionals (espPkgs ? esp-idf-esp32) [
            espPkgs.esp-idf-esp32
          ]) ++ (lib.optionals (espPkgs ? esp-qemu) [
            espPkgs.esp-qemu
          ]) ++ [
            pkgs.cmake
            pkgs.ninja
            pkgs.gcc
            pkgs.zlib
            (pkgs.python3.withPackages (ps: [
              ps.pexpect
              ps.pytest
              ps.websocket-client
            ]))
          ];
          shellHook = ''
            export HOST_CC=${pkgs.stdenv.cc}/bin/cc
            export LUA_SRC_DIR_TARBALL=${luaSrc}
            echo "psi ESP shell ready. Build firmware: cd firmware && idf.py build"
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = buildTools ++ buildDeps { p = pkgs; } ++ [
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
