{
  description = "psi coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Cosmopolitan cross-compiler set (siraben/cosmopkgs). Provides:
    #   - pkgs.cosmocc
    #   - pkgsCosmo       — single-arch cross stdenv (host's native arch)
    #   - pkgsCosmoFat    — fat APE cross stdenv (x86_64 + aarch64)
    #   - pkgsCosmoAarch64
    nixpkgs-cosmo.url = "github:siraben/nixpkgs/siraben/cosmopkgs";

    filnix.url = "github:mbrock/filnix";
    sbomnix.url = "github:tiiuae/sbomnix";
    sirabenOverlay.url = "github:siraben/overlay";
  };

  outputs = { self, nixpkgs, nixpkgs-cosmo, filnix, sbomnix, sirabenOverlay }:
    let
      eachDefaultSystem = f:
        let
          systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
          bySystem = nixpkgs.lib.genAttrs systems f;
        in
          nixpkgs.lib.foldl' nixpkgs.lib.recursiveUpdate { }
            (map (system:
              nixpkgs.lib.mapAttrs (_: value: { ${system} = value; }) bySystem.${system}
            ) systems);
    in
    eachDefaultSystem (system:
      let
        inherit (pkgs) lib;

        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "compcert" ];
        };

        isLinux = pkgs.stdenv.hostPlatform.isLinux;
        cosmoBase = if isLinux then import nixpkgs-cosmo { inherit system; } else null;

        # ---- Common metadata --------------------------------------------

        psiMeta = {
          description = "psi coding agent";
          homepage = "https://github.com/siraben/psi-coding-agent";
          license = lib.licenses.mit;
          maintainers = with lib.maintainers; [ siraben ];
          platforms = lib.platforms.unix;
          mainProgram = "psi";
        };

        isX86_64Linux = system == "x86_64-linux";

        # ---- curl with mbedTLS ------------------------------------------

        mbedtlsLibOnly = p: p.mbedtls.overrideAttrs (old: {
          cmakeFlags = (old.cmakeFlags or []) ++ [
            "-DENABLE_PROGRAMS=OFF"
            "-DENABLE_TESTING=OFF"
          ];
          postConfigure = "";
        });

        curlWithMbedtls = p: let
          mbedtls = mbedtlsLibOnly p;
        in (p.curl.override {
          brotliSupport = false;
          http2Support = false;
          opensslSupport = false;
          idnSupport = false;
          http3Support = false; # mbedTLS does not support curl's QUIC backend.
          pslSupport = false;
          scpSupport = false;   # libssh2 pulls OpenSSL back into the closure.
          gssSupport = false;   # Kerberos pulls OpenSSL back into the closure.
          zstdSupport = false;
        }).overrideAttrs (old: {
          configureFlags = p.lib.remove "--without-ssl" old.configureFlags
            ++ [
              "--with-mbedtls=${p.lib.getDev mbedtls}"
              "--with-ca-bundle=${p.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
          propagatedBuildInputs = old.propagatedBuildInputs ++ [ mbedtls ];
          nativeCheckInputs = p.lib.remove p.openssl (old.nativeCheckInputs or []);
        });

        luaFor = p: p.lua5_5;
        staticLuaFor = p: (p.lua5_5.override { staticOnly = true; }).overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace src/luaconf.h \
              --replace-fail "#define LUA_ROOT  \"$out/\"" \
                             "#define LUA_ROOT  \"./\""
          '';
        });

        # ---- Shared dependency sets -------------------------------------

        buildDeps = { p, curlPkg ? curlWithMbedtls p, luaPkg ? luaFor p }: [
          p.argtable
          p.cjson
          curlPkg
          p.libedit
          luaPkg
          p.zlib
        ];

        buildTools = [ pkgs.gnumake pkgs.pkg-config ];

        devShellHook = ''
          export PSI_LUA_BOOT_FILE="$PWD/lua/boot.lua"
          export HOST_CFLAGS_ZLIB="-I${pkgs.zlib.dev}/include"
          export HOST_LIBS_ZLIB="-L${pkgs.zlib.out}/lib -lz"
        '';

        # ---- Helpers ----------------------------------------------------

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

        mkPsi = { p, stdenv ? p.stdenv, static ? false, extraMakeFlags ? [],
                   extraNativeBuildInputs ? [],
                   deps ? buildDeps { inherit p; },
                   hardeningDisable ? [],
                   extraMeta ? {} }:
          let
            isCross = stdenv.buildPlatform != stdenv.hostPlatform;
            hostCC = "${pkgs.stdenv.cc}/bin/cc";
          in stdenv.mkDerivation (finalAttrs: {
          pname = "psi";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = buildTools ++ extraNativeBuildInputs;

          # Build-platform deps for the embed helper.
          depsBuildBuild = [ pkgs.stdenv.cc ] ++ lib.optionals isCross [ pkgs.zlib ];

          buildInputs = deps;

          enableParallelBuilding = true;
          strictDeps = true;
          inherit hardeningDisable;

          makeFlags = [
            "CC=${stdenv.cc.targetPrefix}cc"
            "HOST_CC=${hostCC}"
            "PKG_CONFIG=pkg-config"
            "CA_BUNDLE_FILE=${p.cacert}/etc/ssl/certs/ca-bundle.crt"
            "LUA_BOOT_FILE=$(out)/share/psi/boot.lua"
          ]
          ++ lib.optionals static [ "STATIC=1" ]
          ++ extraMakeFlags;

          installFlags = [ "PREFIX=$(out)" ];

          # Default nix strip on bin/ is --strip-debug, which leaves
          # .symtab/.strtab intact (~300 KB on the static musl builds).
          # --strip-all drops those too.
          stripAllList = [ "bin" ];

          # Keep the host embed helper on build-platform zlib.
          preBuild = lib.optionalString isCross ''
            makeFlagsArray+=(
              "HOST_CFLAGS_ZLIB=-I${pkgs.zlib.dev}/include"
              "HOST_LIBS_ZLIB=-L${pkgs.zlib.out}/lib -lz"
            )
          '';

          passthru = lib.optionalAttrs
            (stdenv.buildPlatform.canExecute stdenv.hostPlatform)
            {
              tests.version = pkgs.runCommand "${finalAttrs.pname}-version" { } ''
                ${finalAttrs.finalPackage}/bin/psi --version > $out
              '';
            };

          postFixup = lib.optionalString static ''
            rm -f "$out/nix-support/propagated-build-inputs"
            rmdir --ignore-fail-on-non-empty "$out/nix-support" 2>/dev/null || true
          '';

          meta = psiMeta // extraMeta;
        });

        # ---- cosmocc helper ---------------------------------------------

        mkCosmoVariant = { pkgsCosmo, stripDebug ? true }:
          let
            cosmoHardening = [ "fortify" "fortify3" "stackprotector" "pic" ];

            mbedtlsPatched = pkgsCosmo.mbedtls.overrideAttrs (old: {
              hardeningDisable = (old.hardeningDisable or []) ++ cosmoHardening;
              env = (old.env or {}) // {
                NIX_CFLAGS_COMPILE =
                  (old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error";
              };
              cmakeFlags = (old.cmakeFlags or []) ++ [
                "-DCMAKE_C_FLAGS=-Wno-error"
                "-DENABLE_TESTING=OFF"
                "-DENABLE_PROGRAMS=OFF"
                "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF"
                "-DUSE_STATIC_MBEDTLS_LIBRARY=ON"
              ];
              postConfigure = "";
            });

            curlMbedtls = (pkgsCosmo.curl.override {
              brotliSupport = false;
              http2Support = false;
              opensslSupport = false;
              idnSupport = false;
              http3Support = false;
              pslSupport = false;
              scpSupport = false;
              gssSupport = false;
              zstdSupport = false;
            }).overrideAttrs (old: {
              configureFlags = pkgsCosmo.lib.remove "--without-ssl" old.configureFlags
                ++ [ "--with-mbedtls=${pkgsCosmo.lib.getDev mbedtlsPatched}" ];
              propagatedBuildInputs = old.propagatedBuildInputs ++ [ mbedtlsPatched ];
              nativeCheckInputs = pkgsCosmo.lib.remove pkgsCosmo.openssl
                (old.nativeCheckInputs or []);
              hardeningDisable = (old.hardeningDisable or []) ++ cosmoHardening;
              env = (old.env or {}) // {
                NIX_CFLAGS_COMPILE =
                  (old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error";
              };
            });

            cjsonPatched = pkgsCosmo.cjson.overrideAttrs (old: {
              hardeningDisable = (old.hardeningDisable or []) ++ [ "stackprotector" ];
              cmakeFlags = (old.cmakeFlags or []) ++ [
                "-DENABLE_CJSON_TEST=OFF"
                "-DENABLE_CUSTOM_COMPILER_FLAGS=OFF"
              ];
            });
          in
          pkgsCosmo.callPackage ./nix/psi-cosmocc.nix {
            lua = staticLuaFor pkgsCosmo;
            curl = curlMbedtls;
            cacert = pkgsCosmo.cacert;
            cjson = cjsonPatched;
            openssl = null;
            mbedtls = mbedtlsPatched;
            buildCC = pkgs.stdenv.cc;
            buildZlib = pkgs.zlib;
            inherit stripDebug;
          };

        # ---- Optional Linux-only variants -----------------------------

        linuxOnlyPackages = lib.optionalAttrs isLinux {
          psi-static = let p = pkgs.pkgsStatic; in
            mkPsi {
              inherit p;
              static = true;
              deps = buildDeps { inherit p; luaPkg = staticLuaFor p; };
              extraMeta = { platforms = [ "x86_64-linux" "aarch64-linux" ]; };
            };

          psi-static-riscv64 =
            let p = pkgs.pkgsCross.riscv64-musl.pkgsStatic; in
            mkPsi {
              inherit p;
              static = true;
              deps = buildDeps { inherit p; luaPkg = staticLuaFor p; };
              extraMeta = { platforms = [ "riscv64-linux" ]; };
            };

          psi-cosmocc = mkCosmoVariant { pkgsCosmo = cosmoBase.pkgsCosmo; };
          psi-cosmocc-fat = mkCosmoVariant {
            pkgsCosmo = cosmoBase.pkgsCosmoFat;
            stripDebug = false;
          };
        };

        # ---- Optional x86-only variants -------------------------------

        x86OnlyPackages = lib.optionalAttrs isX86_64Linux (let
          gcc46 = pkgs.wrapCCWith {
            cc = pkgs.minimal-bootstrap.gcc46;
            isGNU = true;
          };
          luaC89 = (luaFor pkgs).overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace src/luaconf.h \
                --replace-fail "#define LUA_C89_NUMBERS		0" \
                               "#define LUA_C89_NUMBERS		1"
            '';
            postInstall = (old.postInstall or "") + ''
              substituteInPlace "$out/lib/pkgconfig/lua.pc" \
                --replace-fail "Cflags: -I$out/include" \
                               "Cflags: -I$out/include -DLUA_C89_NUMBERS=1"
              for pc in "$out"/lib/pkgconfig/lua*.pc; do
                if [ "$(basename "$pc")" != lua.pc ]; then
                  rm -f "$pc"
                  ln -s lua.pc "$pc"
                fi
              done
            '';
          });
        in {
          psi-i686 = mkPsi {
            p = pkgs.pkgsi686Linux;
            extraMeta = { platforms = [ "i686-linux" "x86_64-linux" ]; };
          };

          psi-static-i686 =
            let p = pkgs.pkgsi686Linux.pkgsStatic; in
            mkPsi {
              inherit p;
              static = true;
              deps = buildDeps { inherit p; luaPkg = staticLuaFor p; };
              extraMeta = { platforms = [ "i686-linux" "x86_64-linux" ]; };
            };

          psi-tcc = mkPsi {
            p = pkgs;
            extraNativeBuildInputs = [ pkgs.gcc pkgs.tinycc ];
            extraMakeFlags = [
              "CC=tcc" "HOST_CC=cc"
              "STRICT_CFLAGS="
              "RPATH_LDFLAGS=$(LOCAL_RPATH_LDFLAGS)"
            ];
            extraMeta = { platforms = [ "x86_64-linux" "i686-linux" ]; };
          };

          psi-gcc46 = mkPsi {
            p = pkgs;
            deps = buildDeps { p = pkgs; luaPkg = luaC89; };
            extraNativeBuildInputs = [ gcc46 ];
            extraMakeFlags = [ "CC=${gcc46}/bin/cc" ];
            hardeningDisable = [ "all" ];
            extraMeta = { platforms = [ "x86_64-linux" ]; };
          };

          psi-compcert = mkPsi {
            p = pkgs;
            extraNativeBuildInputs = [ pkgs.gcc pkgs.compcert ];
            extraMakeFlags = [ "CC=ccomp" "HOST_CC=cc" "STRICT_CFLAGS=" "DEPFLAGS=" ];
            extraMeta = { platforms = [ "x86_64-linux" ]; };
          };

          psi-filc = psiFilc;
        });

        psiFilc = let
          pkgsFilc = filnix.legacyPackages.${system}.pkgsFilc;
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
          deps = buildDeps {
            p = pkgsFilc;
            curlPkg = pkgsFilc.curl;
            luaPkg = filcLua55;
          };
          extraNativeBuildInputs = [ pkgs.makeWrapper ];
          extraMeta = { platforms = [ "x86_64-linux" ]; };
        }).overrideAttrs (old: {
          postFixup = (old.postFixup or "") + ''
            wrapProgram $out/bin/psi \
              --set SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          '';
        });

      in {

        # ---- Packages ---------------------------------------------------

        packages = {
          psi = mkPsi { p = pkgs; };
          default = self.packages.${system}.psi;
          psi-gcc = self.packages.${system}.psi;
          c-ward = pkgs.callPackage ./nix/c-ward.nix {};

          psi-clang = mkPsi {
            p = pkgs;
            stdenv = pkgs.clangStdenv;
          };
        } // linuxOnlyPackages // x86OnlyPackages;

        # ---- Apps -------------------------------------------------------

        apps = lib.optionalAttrs isLinux {
          valgrind = let
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

          analyze = mkApp {
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

          check-docs = mkApp {
            name = "psi-check-docs";
            description = "Verify @generated:* doc regions match source";
            extraInputs = [ pkgs.gcc pkgs.git ];
            text = ''
              cd "''${PSI_SRC:-$PWD}"
              make check-docs
            '';
          };

          scan-build = let
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
              scan_cppflags=(
                "-isystem" "$(${pkgs.gcc}/bin/gcc -print-file-name=include)"
                "-isystem" "${pkgs.glibc.dev}/include"
              )
              make_args=(
                "BUILD_DIR=''${SCAN_BUILD_BUILD_DIR:-build-scan-build}"
                "analyze-scan-build"
                "CPPFLAGS=''${scan_cppflags[*]}"
                "PSI_CFLAGS_LUA=-I${lib.getDev lua}/include"
                "PSI_LIBS_LUA=-L${lib.getLib lua}/lib -llua"
                "PSI_CFLAGS_CJSON=-I${lib.getDev pkgs.cjson}/include -I${lib.getDev pkgs.cjson}/include/cjson"
                "PSI_LIBS_CJSON=-L${lib.getLib pkgs.cjson}/lib -lcjson"
                "PSI_CFLAGS_CURL=-I${lib.getDev curl}/include"
                "PSI_LIBS_CURL=-L${lib.getLib curl}/lib -lcurl"
                "PSI_CFLAGS_ZLIB=-I${lib.getDev pkgs.zlib}/include"
                "PSI_LIBS_ZLIB=-L${lib.getLib pkgs.zlib}/lib -lz"
                "PSI_CFLAGS_EDIT=-I${lib.getDev pkgs.libedit}/include -I${lib.getDev pkgs.libedit}/include/editline"
                "PSI_LIBS_EDIT=-L${lib.getLib pkgs.libedit}/lib -ledit"
                "PSI_CFLAGS_ARGTABLE=-I${lib.getDev pkgs.argtable}/include"
                "PSI_LIBS_ARGTABLE=-L${lib.getLib pkgs.argtable}/lib -largtable3"
                "HOST_CFLAGS_ZLIB=''${scan_cppflags[*]} -I${lib.getDev pkgs.zlib}/include"
                "HOST_LIBS_ZLIB=-L${lib.getLib pkgs.zlib}/lib -lz"
              )
              make "''${make_args[@]}"
            '';
          };

          lint = mkApp {
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
              echo "=== docs drift ==="
              make check-docs
            '';
          };

          infer = let
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
              infer_cppflags=(
                "-isystem" "$(${pkgs.gcc}/bin/gcc -print-file-name=include)"
                "-isystem" "${pkgs.glibc.dev}/include"
              )
              make_args=(
                "BUILD_DIR=$build_dir"
                "analyze-infer"
                "CPPFLAGS=''${infer_cppflags[*]}"
                "PSI_CFLAGS_LUA=-I${lib.getDev lua}/include"
                "PSI_LIBS_LUA=-L${lib.getLib lua}/lib -llua"
                "PSI_CFLAGS_CJSON=-I${lib.getDev pkgs.cjson}/include -I${lib.getDev pkgs.cjson}/include/cjson"
                "PSI_LIBS_CJSON=-L${lib.getLib pkgs.cjson}/lib -lcjson"
                "PSI_CFLAGS_CURL=-I${lib.getDev curl}/include"
                "PSI_LIBS_CURL=-L${lib.getLib curl}/lib -lcurl"
                "PSI_CFLAGS_ZLIB=-I${lib.getDev pkgs.zlib}/include"
                "PSI_LIBS_ZLIB=-L${lib.getLib pkgs.zlib}/lib -lz"
                "PSI_CFLAGS_EDIT=-I${lib.getDev pkgs.libedit}/include -I${lib.getDev pkgs.libedit}/include/editline"
                "PSI_LIBS_EDIT=-L${lib.getLib pkgs.libedit}/lib -ledit"
                "PSI_CFLAGS_ARGTABLE=-I${lib.getDev pkgs.argtable}/include"
                "PSI_LIBS_ARGTABLE=-L${lib.getLib pkgs.argtable}/lib -largtable3"
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

          cc-diversity = mkApp {
            name = "psi-cc-diversity";
            description = "Build psi with GCC, Clang, and TinyCC";
            extraInputs = [ pkgs.gcc pkgs.clang pkgs.tinycc ];
            text = ''
              cd "''${PSI_SRC:-$PWD}"
              rm -rf build-gcc build-clang build-tcc
              make BUILD_DIR=build-gcc CC=gcc
              make BUILD_DIR=build-clang CC=clang
              make BUILD_DIR=build-tcc CC=tcc HOST_CC=cc STRICT_CFLAGS= "RPATH_LDFLAGS=\$(LOCAL_RPATH_LDFLAGS)"
            '';
          };

          audit-sbom = mkApp {
            name = "psi-audit-sbom";
            description = "Generate and audit runtime SBOM artifacts";
            extraInputs = [
              pkgs.nix
              pkgs.python3
              sbomnix.packages.${system}.sbomnix
            ];
            text = ''
              cd "''${PSI_SRC:-$PWD}"
              exec python3 scripts/sbom-audit.py "$@"
            '';
          };
        };

        # ---- Dev shells -------------------------------------------------

        devShells = (lib.optionalAttrs isLinux {
          compcert = pkgs.mkShell {
            packages = buildTools ++ buildDeps { p = pkgs; } ++ [
              pkgs.compcert
              pkgs.gcc
            ];
            shellHook = devShellHook;
          };
        }) // {
          default = pkgs.mkShell {
            packages = buildTools ++ buildDeps { p = pkgs; } ++ [
              pkgs.clang
              pkgs.clang-tools
              pkgs.cppcheck
              pkgs.fd
              pkgs.lua54Packages.luacheck
              (pkgs.python3.withPackages (ps: [
                ps.pexpect
                ps.pyte
                ps.pytest
              ]))
              pkgs.ripgrep
              pkgs.stylua
            ] ++ lib.optionals isLinux [
              pkgs.gdb
              pkgs.tinycc
              pkgs.valgrind
            ];
            shellHook = devShellHook;
          };
        };
      });
}
