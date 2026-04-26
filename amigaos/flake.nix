{
  description = "psi cross-toolchain + emulator for AmigaOS m68k";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # ----------------------------------------------------------
        # vasm — Volker Barthelmann's portable assembler.
        # Built with CPU=m68k and Motorola syntax for AmigaOS HUNK
        # output. Produces `vasmm68k_mot`. Source is a flat tarball
        # with a top-level `vasm/` directory; we cd into it.
        # ----------------------------------------------------------
        vasm-m68k = pkgs.stdenv.mkDerivation {
          pname = "vasm-m68k-mot";
          version = "1.9k"; # tarball is undated; track upstream loosely

          src = pkgs.fetchurl {
            url = "http://sun.hasenbraten.de/vasm/release/vasm.tar.gz";
            hash = "sha256-xzcCV06NahVKfWTyLXthjQuFrOmOyetj1efF7GluOms=";
          };

          # Vendor unpacks into a `vasm/` subdir.
          sourceRoot = "vasm";

          nativeBuildInputs = [ pkgs.gnumake ];

          # Upstream Makefile assumes a specific layout; just call its
          # m68k-mot config and copy the binary out.
          buildPhase = ''
            runHook preBuild
            make CPU=m68k SYNTAX=mot
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp vasmm68k_mot $out/bin/
            cp vobjdump $out/bin/ || true
            runHook postInstall
          '';

          meta = {
            description = "Portable assembler (m68k Motorola syntax for AmigaOS)";
            homepage = "http://sun.hasenbraten.de/vasm/";
            license = pkgs.lib.licenses.unfree; # vasm is freeware, not OSI
            platforms = pkgs.lib.platforms.unix;
          };
        };

        # ----------------------------------------------------------
        # vlink — companion linker. Plain Unix Makefile.
        # ----------------------------------------------------------
        vlink = pkgs.stdenv.mkDerivation {
          pname = "vlink";
          version = "0.18a";

          src = pkgs.fetchurl {
            url = "http://sun.hasenbraten.de/vlink/release/vlink.tar.gz";
            hash = "sha256-jRUc3TCk/rV1o2TmiBDCvDAP4afAdNu+5v0RdabFv64=";
          };

          sourceRoot = "vlink";

          nativeBuildInputs = [ pkgs.gnumake ];

          # Default Makefile builds the host-native vlink supporting
          # all targets including AmigaHunk.
          buildPhase = ''
            runHook preBuild
            mkdir -p objects
            make
            runHook postBuild
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp vlink $out/bin/
          '';

          meta = {
            description = "Multi-format linker (Amiga HUNK, ELF, a.out, …)";
            homepage = "http://sun.hasenbraten.de/vlink/";
            license = pkgs.lib.licenses.unfree;
            platforms = pkgs.lib.platforms.unix;
          };
        };

        # ----------------------------------------------------------
        # vbcc — the C compiler that drives vasm + vlink. Generates
        # m68k assembly, then `vc` (the frontend) shells out to vasm
        # and vlink. Build needs gnu89 + -fcommon + relaxed prototype
        # checks because vbcc's source predates GCC 14's stricter
        # default. We patch one Makefile and override CC.
        # ----------------------------------------------------------
        vbcc-m68k = pkgs.stdenv.mkDerivation {
          pname = "vbcc-m68k";
          version = "0.9j";

          src = pkgs.fetchurl {
            url = "http://www.ibaug.de/vbcc/vbcc.tar.gz";
            hash = "sha256-Z+IhBitQ+1kGE0h+wpSKANuAVS4GG740jm6u1bM/Cvg=";
          };

          sourceRoot = "vbcc";

          nativeBuildInputs = [ pkgs.gnumake ];

          # nixpkgs's stdenv injects -Werror=format-security via the
          # `format` hardening pass, which vbcc's pre-C99 source can't
          # satisfy (lots of `printf(literal_var)` patterns). Disable
          # the hardening passes that fight pre-C99 idioms.
          hardeningDisable = [ "format" "fortify" ];

          # The make targets read $TARGET to pick the backend.
          # GCC 14 default-promotes implicit-function-declaration to
          # an error; vbcc's source uses K&R-ish forward refs all over
          # the place, so we need -Wno-error= to keep it a warning.
          # -fcommon restores the pre-GCC-10 tentative-definition
          # behaviour the source assumes.
          buildPhase = ''
            runHook preBuild
            mkdir -p bin
            mkdir -p objects

            # `dtgen` (datatype-table generator that runs as a build
            # step) is interactive: it prompts "Type y or n [y]: " for
            # every type bucket and reads stdin. With no TTY in the
            # sandbox, fgets returns NULL on EOF and the do-while
            # spins forever on uninitialised memory — observed: 30+
            # minutes pegging a core. Feed an infinite stream of
            # newlines so each prompt accepts its default ("y" or
            # an existing-type token), and dtgen terminates promptly.
            (yes "" | make TARGET=m68k \
                 CC="gcc -std=gnu89 -g -DHAVE_AOS4 -fcommon \
                     -fno-asm \
                     -Wno-error=implicit-function-declaration \
                     -Wno-error=incompatible-pointer-types \
                     -Wno-error=int-conversion \
                     -Wno-error=implicit-int \
                     -Wno-format-security \
                     -Wno-error=format-security \
                     -Wno-unused-result \
                     -Wno-error=unused-result") || true
            # Re-run as a normal make to surface real errors after the
            # dtgen-piped stage has produced dt.h / dt.c.
            make TARGET=m68k \
                 CC="gcc -std=gnu89 -g -DHAVE_AOS4 -fcommon \
                     -fno-asm \
                     -Wno-error=implicit-function-declaration \
                     -Wno-error=incompatible-pointer-types \
                     -Wno-error=int-conversion \
                     -Wno-error=implicit-int \
                     -Wno-format-security \
                     -Wno-error=format-security \
                     -Wno-unused-result \
                     -Wno-error=unused-result"
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            # vbcc produces backends named vbcc<TARGET> in bin/.
            for f in bin/vbccm68k bin/vbccm68ks bin/vc bin/vprof bin/dtgen; do
              if [ -f "$f" ]; then cp "$f" "$out/bin/"; fi
            done
            runHook postInstall
          '';

          meta = {
            description = "vbcc C compiler targeting m68k AmigaOS";
            homepage = "http://www.compilers.de/vbcc.html";
            license = pkgs.lib.licenses.unfree;
            platforms = pkgs.lib.platforms.unix;
          };
        };

        # ----------------------------------------------------------
        # vbcc-target-m68k-amigaos — config files + NDK headers + libs.
        #
        # vbcc itself is just a code generator; to actually build
        # AmigaOS executables you need a target package shipping:
        #   config/aos68k         — `vc` driver config telling it how
        #                           to invoke vasmm68k_mot + vlink with
        #                           the right flags / libs / startup.
        #   targets/m68k-amigaos/include/  — NDK headers + libnix-style
        #                                    POSIX-ish stdio / stdlib.
        #   targets/m68k-amigaos/lib/      — libamiga.lib, libdebug.lib,
        #                                    libvc.a, startup objects.
        #
        # Distributed as an LHA archive at
        # http://phoenix.owl.de/vbcc/2022-05-22/vbcc_target_m68k-amigaos.lha
        # — courtesy of Frank Wille (vbcc author). Marked unfree because
        # it bundles the AmigaOS NDK whose headers are not freely
        # licensed by Hyperion / Cloanto, even though redistributed by
        # vbcc-the-project.
        # ----------------------------------------------------------
        vbcc-target-m68k-amigaos = pkgs.stdenv.mkDerivation {
          pname = "vbcc-target-m68k-amigaos";
          version = "2022-05-22";

          src = pkgs.fetchurl {
            url = "http://phoenix.owl.de/vbcc/2022-05-22/vbcc_target_m68k-amigaos.lha";
            hash = "sha256-7HNNcRU1nNtdHHA0koTsvVcS70fovCjUFQEXxvjHMok=";
          };

          # LHA isn't a tar; nixpkgs unpacker doesn't know it. Skip
          # the default unpack and do it ourselves with lhasa.
          dontUnpack = true;

          nativeBuildInputs = [ pkgs.lhasa ];

          buildPhase = ''
            runHook preBuild
            mkdir extract
            (cd extract && lha x $src)
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            # The archive root is `vbcc_target_m68k-amigaos/`; flatten
            # to $out so `$VBCC` can point at it directly.
            cp -r extract/vbcc_target_m68k-amigaos/. $out/
            runHook postInstall
          '';

          meta = {
            description = "vbcc m68k AmigaOS target: config, NDK headers, libs";
            homepage = "http://www.compilers.de/vbcc.html";
            license = pkgs.lib.licenses.unfree;
            platforms = pkgs.lib.platforms.unix;
          };
        };

        # ----------------------------------------------------------
        # amiga-toolchain — convenience aggregate. Composes vasm,
        # vlink, vbcc and the m68k target package, plus a wrapper
        # script that exports VBCC and sets the config search path
        # so plain `vc +aos68k -o hello hello.c` works.
        # ----------------------------------------------------------
        amiga-toolchain = pkgs.symlinkJoin {
          name = "amiga-toolchain";
          paths = [ vasm-m68k vlink vbcc-m68k vbcc-target-m68k-amigaos ];
          # vc reads $VBCC/config/<target>. The shipped config uses
          # AmigaDOS-style volume assigns (`vincludeos3:`, `vlibos3:`)
          # which only work on real Amiga or with assigns set up. On
          # Linux we rewrite them to the real on-disk paths inside the
          # composed tree. symlinkJoin links the config file in
          # read-only; we delete the link and write a real file in
          # its place. We also set up assigns-as-symlinks so any vc
          # / vasm / vlink invocation that DOES dereference the colon
          # syntax (some tools do, some don't) lands in the right
          # place.
          postBuild = ''
            # Replace symlinked config files with rewritten copies.
            # Three things need patching:
            #   1. vincludeos3:  → $out/targets/m68k-amigaos/include/
            #   2. vlibos3:      → $out/targets/m68k-amigaos/lib/
            #   3. -rm=delete    → -rm=rm -f
            #      (vbcc's `vc` driver invokes `delete` to clean up
            #      intermediate .asm files; that's the AmigaDOS
            #      command, not on Linux. Without this patch, every
            #      compile produces a "delete: not found" error AND
            #      causes Make to fail because vc returns non-zero.)
            for cfg in aos68k aos68km aos68kr; do
              real="$out/config/$cfg"
              if [ -L "$real" ]; then
                target=$(readlink -f "$real")
                rm "$real"
                sed -e "s|vincludeos3:|$out/targets/m68k-amigaos/include/|g" \
                    -e "s|vlibos3:|$out/targets/m68k-amigaos/lib/|g" \
                    -e "s|^-rm=delete quiet|-rm=rm -f|" \
                    -e "s|^-rmv=delete |-rmv=rm -f -v |" \
                    "$target" > "$real"
              fi
            done

            # Convenience wrapper: `vc-aos68k hello.c -o hello`
            mkdir -p $out/wrapped
            cat > $out/wrapped/vc-aos68k <<EOF
#!${pkgs.bash}/bin/bash
export VBCC=$out
exec $out/bin/vc +aos68k "\$@"
EOF
            chmod +x $out/wrapped/vc-aos68k
          '';
        };

        # ----------------------------------------------------------
        # lua-amigaos — Lua 5.4 cross-compiled to m68k AmigaOS HUNK.
        #
        # Lua's reference Makefile builds a single static interpreter
        # binary by default. We invoke it through `vc` and pass the
        # `+aos68k` driver flag. Lua's source is portable C99-ish; the
        # only patches needed are:
        #   * disable readline (no libedit on AmigaOS)
        #   * skip dynamic loading (no shared libs on classic Amiga)
        #   * route Lua's tmpfile() to AmigaDOS T: assign instead of
        #     POSIX P_tmpdir
        # The first two are flag-toggles; the third only matters at
        # runtime so we'll handle it in psi's bridging layer later.
        # ----------------------------------------------------------
        lua-amigaos = pkgs.stdenv.mkDerivation {
          pname = "lua-amigaos";
          version = "5.4.7";

          src = pkgs.fetchurl {
            url = "https://www.lua.org/ftp/lua-5.4.7.tar.gz";
            hash = "sha256-n79eKO+GxphY9tPTTszDLpEcGii0Eg/z6EqqcM+/HjA=";
          };

          # Lua source ships under `lua-5.4.7/`.
          sourceRoot = "lua-5.4.7";

          nativeBuildInputs = [ pkgs.gnumake amiga-toolchain ];

          # Lua's Makefile selects the platform via a top-level target
          # (linux, macosx, …). There's no aos/amigaos preset; we
          # write our own here. CC=vc routes to the cross-toolchain,
          # which transparently invokes vasm + vlink.
          buildPhase = ''
            runHook preBuild
            export VBCC=${amiga-toolchain}
            cd src
            # Phase 1: liblua.a + the host objects. Skip Lua's
            # platform-specific `linux`/`macosx` targets — those
            # define LUA_USE_LINUX / LUA_USE_POSIX which pull in
            # POSIX headers (sys/wait.h, dlfcn.h) the AmigaOS NDK
            # doesn't have. The bare `make a` target compiles
            # generic-portable Lua with C89 only.
            #
            # vbcc doesn't recognise GCC syntax: `-Wall` is "Unknown
            # Flag", duplicate `-O2 -O1` is rejected. Override Lua's
            # gcc-flavoured WARN/SYSCFLAGS and pin to vbcc's `-O=1`.
            make a CC="vc +aos68k" \
                   AR="vlink -bamigahunk -r -Cvbcc -Bstatic -o" \
                   RANLIB=true \
                   WARN="" \
                   SYSCFLAGS="" \
                   CFLAGS="-O=1 -DLUA_COMPAT_5_3 -DLUA_USE_C89" \
                   MYCFLAGS="" \
                   MYLIBS=""

            # Phase 2: link the `lua` interpreter binary. The default
            # rule wants `gcc -lreadline` etc.; build it manually
            # against liblua.a + lua.o we just produced.
            vc +aos68k -O=1 -DLUA_COMPAT_5_3 -DLUA_USE_C89 -c -o lua.o lua.c
            # `-lmieee` provides the MathIeee*Base global pointers that
            # vbcc-compiled code references for double math even with
            # `-amiga-softfloat`. (Despite the name, the softfloat
            # flag changes ONLY whether the FPU is used; doubles are
            # still passed through AmigaOS's MathIeeeDoubBas/Trans
            # library bases.) `-lamiga` provides the exec/dos bridge
            # symbols for OpenLibrary calls.
            vc +aos68k -o lua lua.o liblua.a -lmieee -lamiga
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/lib $out/include
            cp lua $out/bin/lua 2>/dev/null || echo "interpreter not produced"
            cp liblua.a $out/lib/ 2>/dev/null || true
            cp lua.h luaconf.h lualib.h lauxlib.h lua.hpp $out/include/ 2>/dev/null || true
            runHook postInstall
          '';

          meta = {
            description = "Lua 5.4 cross-compiled to m68k AmigaOS HUNK";
            homepage = "https://www.lua.org/";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.unix;
          };
        };

        # ----------------------------------------------------------
        # amitools (vamos) — userspace m68k Amiga emulator. Lets us
        # run AmigaDOS binaries on Linux without Kickstart ROMs by
        # stubbing exec.library / dos.library natively. Used for
        # autonomous testing.
        # ----------------------------------------------------------
        # Sibling package: pure Python wrapper around the Musashi
        # 68k emulator core. Imported by amitools/vamos as
        # `machine68k`. Same author, separate repo.
        machine68k = pkgs.python3Packages.buildPythonPackage {
          pname = "machine68k";
          version = "0.4.1";
          format = "pyproject";

          src = pkgs.fetchFromGitHub {
            owner = "cnvogelg";
            repo = "machine68k";
            rev = "v0.4.1";
            # Will be filled by `nix build` and re-run.
            hash = "sha256-N/dbSWk6bQeX2REsgvbwxH3BZIZKQyEVq2jL56d28B0=";
          };

          nativeBuildInputs = with pkgs.python3Packages; [
            setuptools
            setuptools-scm
            cython
            wheel
          ];

          SETUPTOOLS_SCM_PRETEND_VERSION = "0.4.1";

          doCheck = false;

          meta.description = "Python bindings for the Musashi m68k emulator (used by vamos)";
        };

        amitools = pkgs.python3Packages.buildPythonApplication {
          pname = "amitools";
          # The 0.8.1 release expects machine68k.Traps.set_exc_func()
          # which the latest released machine68k (0.4.1) does NOT
          # expose. cnvogelg/amitools `main` rewrote _setup_handler
          # to use the API that machine68k 0.4.1 actually has, so
          # pin to a main commit until the next paired release.
          version = "0.8.1+main";
          format = "pyproject";

          src = pkgs.fetchFromGitHub {
            owner = "cnvogelg";
            repo = "amitools";
            rev = "3b57f2052ee76c28bbc5e4256227f62dca7b1c9f";
            hash = "sha256-2Rx4xIpbDA2xFqKyJM4ssRS0ruuNfK956KDvYb/TscI=";
          };

          nativeBuildInputs = with pkgs.python3Packages; [
            setuptools
            setuptools-scm
            cython
            wheel
          ];

          # setuptools_scm derives the version from git metadata; we
          # have a tarball without `.git`, so pin via env.
          SETUPTOOLS_SCM_PRETEND_VERSION = "0.8.1";

          # vamos imports machine68k for the m68k CPU emulator core,
          # and greenlet for cooperative scheduling of native tasks.
          propagatedBuildInputs = [ machine68k pkgs.python3Packages.greenlet ];

          # vamos's m68k CPU emulator is a Cython extension; it builds
          # automatically via setuptools.
          doCheck = false;

          meta = {
            description = "Tools for AmigaOS programming + vamos m68k userspace emulator";
            homepage = "https://github.com/cnvogelg/amitools";
            license = pkgs.lib.licenses.gpl2Plus;
            platforms = pkgs.lib.platforms.unix;
          };
        };

        # ----------------------------------------------------------
        # embed-lua-raw — host-native build of our zlib-free embedder.
        # Runs at build time to bake `lua/psi/*.lua` into a C array
        # consumed by psi-amigaos. The standard scripts/embed_lua.c
        # uses zlib, which we don't want in the m68k cross-build.
        # ----------------------------------------------------------
        embed-lua-raw = pkgs.stdenv.mkDerivation {
          pname = "embed-lua-raw";
          version = "0.1.0";
          src = ./scripts;

          buildPhase = ''
            runHook preBuild
            mkdir -p inc/psi
            cat > inc/psi/embedded_lua.h <<'EOF'
            #ifndef PSI_EMBEDDED_LUA_H
            #define PSI_EMBEDDED_LUA_H
            #include <stddef.h>
            struct psi_embedded_lua {
                const char *name;
                const unsigned char *src;
                size_t len;
                size_t raw_len;
            };
            extern const struct psi_embedded_lua psi_embedded_lua_table[];
            #endif
            EOF
            cc -O2 -Iinc -o embed_lua_raw embed_lua_raw.c
            runHook postBuild
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp embed_lua_raw $out/bin/
          '';
        };

        # ----------------------------------------------------------
        # psi-amigaos — v1.1 entry point with embedded Lua bootstrap.
        # eval / print / version. Bakes lua/psi/*.lua into the binary
        # via embed-lua-raw so require("psi.prompt") etc. resolve
        # without a filesystem.
        # ----------------------------------------------------------
        psi-amigaos = pkgs.stdenv.mkDerivation {
          pname = "psi-amigaos";
          version = "0.1.0";

          # We need both the C shim (./psi-shim) and the Lua sources
          # (../lua/). Compose them into a synthetic source root.
          src = pkgs.runCommand "psi-amigaos-src" {} ''
            mkdir -p $out/psi-shim $out/lua/psi $out/include/psi
            cp ${./psi-shim}/main.c $out/psi-shim/
            cp ${../lua}/boot.lua $out/lua/
            cp ${../lua/psi}/*.lua $out/lua/psi/
            cp ${./psi-shim}/../scripts/../scripts/embedded_lua_template.h $out/include/psi/embedded_lua.h 2>/dev/null || true
          '';

          nativeBuildInputs = [ amiga-toolchain embed-lua-raw ];

          dontConfigure = true;
          dontPatch = true;

          buildPhase = ''
            runHook preBuild
            export VBCC=${amiga-toolchain}

            # Generate include/psi/embedded_lua.h that the shim needs.
            mkdir -p include/psi
            cat > include/psi/embedded_lua.h <<'EOF'
            #ifndef PSI_EMBEDDED_LUA_H
            #define PSI_EMBEDDED_LUA_H
            #include <stddef.h>
            struct psi_embedded_lua {
                const char *name;
                const unsigned char *src;
                size_t len;
                size_t raw_len;
            };
            extern const struct psi_embedded_lua psi_embedded_lua_table[];
            #endif
            EOF

            # Bake the Lua modules. Bundle every file under lua/.
            ${embed-lua-raw}/bin/embed_lua_raw \
              lua/boot.lua \
              lua/psi/prelude.lua \
              lua/psi/records.lua \
              lua/psi/ansi.lua \
              lua/psi/diff.lua \
              lua/psi/context.lua \
              lua/psi/events.lua \
              lua/psi/platform.lua \
              lua/psi/sched.lua \
              lua/psi/session.lua \
              lua/psi/tool_registry.lua \
              lua/psi/tool_shell.lua \
              lua/psi/tools.lua \
              lua/psi/render.lua \
              lua/psi/markdown.lua \
              lua/psi/prompt.lua \
              lua/psi/prompt_templates.lua \
              lua/psi/commands.lua \
              lua/psi/modes.lua \
              lua/psi/tui.lua \
              > embedded_lua.c

            # Build the embedded data + the shim, link statically
            # against liblua.a. vbcc accepts unsigned-char arrays
            # fine; large literal byte arrays compile a bit slow but
            # work.
            vc +aos68k -O=0 -DLUA_USE_C89 -Iinclude \
                -c -o embedded_lua.o embedded_lua.c
            vc +aos68k -O=1 -DLUA_USE_C89 -Iinclude \
                -I${lua-amigaos}/include \
                -c -o main.o psi-shim/main.c
            vc +aos68k -o psi main.o embedded_lua.o \
                ${lua-amigaos}/lib/liblua.a \
                -lmieee -lamiga
            runHook postBuild
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp psi $out/bin/psi
          '';

          meta = {
            description = "psi v1.1 entry point for AmigaOS m68k (embedded Lua)";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.unix;
          };
        };

      in {
        packages = {
          inherit vasm-m68k vlink vbcc-m68k vbcc-target-m68k-amigaos
                  amiga-toolchain machine68k amitools lua-amigaos
                  embed-lua-raw psi-amigaos;
          default = amiga-toolchain;
        };

        # `nix develop .#cross` drops you into a shell with the
        # toolchain on PATH plus host build essentials.
        devShells.cross = pkgs.mkShell {
          buildInputs = [ amiga-toolchain pkgs.gnumake pkgs.coreutils ];
          shellHook = ''
            echo "AmigaOS m68k cross-toolchain ready:"
            echo "  vasmm68k_mot $(vasmm68k_mot 2>&1 | head -1)"
            echo "  vlink        $(vlink -V 2>&1 | head -1 || echo '(no -V)')"
            echo "  vc           $(vc --help 2>&1 | head -1 || echo '(no --help)')"
          '';
        };
      });
}
