{ lib
, stdenv
, gnumake
, argtable
, cjson
, curl
, lua5_4
# Build-platform tools — passed in from the flake. nativeBuildInputs
# splicing in cosmopkgs gives us cross artefacts (target triple in
# path), so we route around it for the host helper.
, buildCC
, buildZlib
# cosmocc toolchain — needed to find its bundled third_party/zlib
# headers. Passed explicitly because referencing stdenv.cc's full
# path via the wrapper attribute is fragile across cosmocc 2.x/4.x.
, cosmocc
}:

# psi compiled against the cosmopkgs cross stdenv (pkgsCosmo /
# pkgsCosmoFat). Produces a static, no-glibc binary — single-arch on
# pkgsCosmo, fat APE polyglot on pkgsCosmoFat.
#
# Key design points:
#
# - No pkg-config in nativeBuildInputs. The Makefile's S9fES escape
#   hatch (PSI_CFLAGS_<DEP> / PSI_LIBS_<DEP>) lets us bypass the
#   pkg-config-cross derivation entirely. That matters because
#   pkg-config-cross transitively needs cross-glibc-nolibgcc, which
#   is the build that fails on the current cosmopkgs nixpkgs base.
#
# - TUI and libedit are disabled. ncurses + termios + readline aren't
#   meaningfully cosmocc-compatible (cosmopolitan resolves termios
#   constants at run time, breaking libedit's ttymodes static init),
#   and the TUI requires ncurses anyway. ANSI / colour rendering is
#   kept on — the lua side still produces colourised output, just
#   line-buffered rather than fullscreen.
#
# - STATIC=1 plus pkg-config-style --static flags so curl pulls its
#   transitive openssl/zlib/etc. into the link line.
#
# - dontStrip / dontPatchELF: cosmocc emits APE polyglot bytes that
#   nixpkgs's default fixup phases would corrupt.

stdenv.mkDerivation {
  pname = "psi-cosmocc";
  version = "0.1.0";

  src = lib.cleanSource ./..;

  nativeBuildInputs = [ gnumake ];

  # The Makefile's embed_lua rule shells out to pkg-config for zlib.
  # In this cross context that resolves to the cosmocc-cross zlib,
  # which native cc can't link. Replace those shell-outs with our
  # own envvars pointing at the build-platform zlib.
  postPatch = ''
    substituteInPlace Makefile \
      --replace-fail '$(shell $(PKG_CONFIG) --cflags zlib)' '$(HOST_ZLIB_CFLAGS)' \
      --replace-fail '$(shell $(PKG_CONFIG) --libs zlib)'   '$(HOST_ZLIB_LIBS)'
  '';

  # zlib intentionally NOT in buildInputs — cosmocc's libcosmo.a
  # provides _Cz_zlib symbols and its bundled third_party/zlib/zlib.h
  # rewrites the standard names onto them. Adding nixpkgs's zlib here
  # would put its plain zlib.h ahead of cosmocc's on the include path
  # and break the symbol-rename trick.
  buildInputs = [
    argtable
    cjson
    curl
    lua5_4
  ];

  # Use a bash array (set in preBuild) so multi-token values like
  # `-L/path -lz` aren't word-split. Plain `makeFlags` shell-splits;
  # `makeFlagsArray` only honours bash arrays set imperatively.
  preBuild = ''
    makeFlagsArray+=(
      "PREFIX=$out"
      "CC=${stdenv.cc.targetPrefix}cc"
      "HOST_CC=${buildCC}/bin/cc"
      "HOST_ZLIB_CFLAGS=-I${lib.getDev buildZlib}/include"
      "HOST_ZLIB_LIBS=-L${lib.getLib buildZlib}/lib -lz"
      "STATIC=1"
      "TUI=0"
      "REPL_EDITLINE=0"
      "LUA_BOOT_FILE=$out/share/psi/boot.lua"
      "PSI_CFLAGS_LUA=-I${lua5_4}/include"
      "PSI_LIBS_LUA=-L${lua5_4}/lib -llua"
      "PSI_CFLAGS_CJSON=-I${cjson}/include"
      "PSI_LIBS_CJSON=-L${cjson}/lib -lcjson"
      "PSI_CFLAGS_CURL=-I${curl.dev}/include"
      "PSI_LIBS_CURL=-L${curl.out}/lib -lcurl"
      # cosmocc bundles zlib in its own third_party/ tree:
      #   - libcosmo.a (auto-linked) provides _Cz_compress / _Cz_uncompress / ...
      #   - include/third_party/zlib/zlib.h #defines the standard
      #     names (compress, uncompress, ...) onto those, so a plain
      #     `#include <zlib.h>` works once that dir is on the path.
      # We MUST NOT use nixpkgs's plain zlib.h — vm.c would see the
      # un-renamed symbols and the link fails. Empty PSI_LIBS_ZLIB
      # since libcosmo provides the symbols already.
      "PSI_CFLAGS_ZLIB=-I${cosmocc}/include/third_party/zlib"
      "PSI_LIBS_ZLIB="
      "PSI_CFLAGS_ARGTABLE=-I${argtable}/include"
      "PSI_LIBS_ARGTABLE=-L${argtable}/lib -largtable3"
      "PSI_CFLAGS_EDIT="
      "PSI_LIBS_EDIT="
    )
  '';

  installPhase = ''
    runHook preInstall
    make PREFIX=$out install
    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;
  dontPatchShebangs = true;

  meta = {
    description = "psi coding agent built as a static, no-glibc binary via cosmocc";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
