{ lib
, stdenv
, gnumake
, fetchurl
, argtable
, curl
# TLS: pass exactly one of `openssl` or `mbedtls`; the other should
# be null. Curl is already configured for whichever backend by the
# flake; this derivation only needs to know which static libs to
# link against.
, openssl ? null
, mbedtls ? null
, zlib
, cacert
, mcfgthreads
, winpthreads
, buildCC
, buildZlib
}:

assert openssl != null || mbedtls != null;
let
  tlsLibs =
    if openssl != null then "-L${lib.getLib openssl}/lib -lssl -lcrypto"
    else "-L${lib.getLib mbedtls}/lib -lmbedtls -lmbedx509 -lmbedcrypto";
  tlsBuildInputs = lib.optional (openssl != null) openssl
                ++ lib.optional (mbedtls != null) mbedtls;
in

# Cross-compiled Windows build of psi. See docs/portability.md for
# what's stubbed (TUI/libedit) and the TLS-backend rationale.
# nixpkgs doesn't ship cjson or lua5.5 for the mingw target, so this
# derivation vendors both via fetchurl. STRICT_CFLAGS drops -pedantic
# because <windows.h> uses C99 features (long long, anon unions) that
# the strict C89 mode rejects.

let
  luaSrc = fetchurl {
    url = "https://www.lua.org/ftp/lua-5.5.0.tar.gz";
    hash = "sha256-V8zDK7vQBcq3W8xSREBSU1r2kXiduiuQFtXFBkDWiz0=";
  };

  cjsonSrc = fetchurl {
    url = "https://github.com/DaveGamble/cJSON/archive/refs/tags/v1.7.18.tar.gz";
    hash = "sha256-OqgGhEoDRCwAdpuD6ZlwvnD77wNzX/iY9IEd0DufXuU=";
  };

  ccPrefix = stdenv.cc.targetPrefix;

  # Lua's `make mingw` target also builds the standalone lua.exe,
  # which pulls in lua.c that unconditionally uses sigaction. We
  # only need liblua.a, so compile the core sources directly.
  lua55-mingw = stdenv.mkDerivation {
    pname = "lua-mingw";
    version = "5.5.0";
    src = luaSrc;
    nativeBuildInputs = [ gnumake ];
    enableParallelBuilding = true;
    buildPhase = ''
      runHook preBuild
      cd src
      cores=$(ls *.c | grep -vE '^(lua|luac|onelua|ltests)\.c$')
      printf '%s\n' $cores | xargs -P "$NIX_BUILD_CORES" -I{} \
        ${ccPrefix}gcc -O2 -c {} -o {}.o
      ${ccPrefix}ar rcs liblua.a *.c.o
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/include $out/lib
      cp liblua.a $out/lib/
      cp lua.h lualib.h lauxlib.h luaconf.h $out/include/
      runHook postInstall
    '';
    dontStrip = true;
  };

  # Skip CMake — we just need cJSON.c + cJSON.h compiled into a
  # static lib. Building cJSON's full CMake project pulls in test
  # binaries and shared-lib infra that mingw cross doesn't need.
  cjson-mingw = stdenv.mkDerivation {
    pname = "cjson-mingw";
    version = "1.7.18";
    src = cjsonSrc;
    buildPhase = ''
      runHook preBuild
      ${ccPrefix}gcc -O2 -c cJSON.c -o cJSON.o
      ${ccPrefix}ar rcs libcjson.a cJSON.o
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/include/cjson $out/lib
      cp cJSON.h $out/include/cjson/
      cp libcjson.a $out/lib/
      runHook postInstall
    '';
    dontStrip = true;
  };

in
stdenv.mkDerivation {
  pname = "psi-mingw";
  version = "0.1.0";

  src = lib.cleanSource ./..;

  nativeBuildInputs = [ gnumake ];
  enableParallelBuilding = true;

  buildInputs = [
    argtable
    curl
    zlib
    mcfgthreads
    winpthreads
    lua55-mingw
    cjson-mingw
  ] ++ tlsBuildInputs;

  preBuild = ''
    makeFlagsArray+=(
      "PREFIX=$out"
      "CC=${ccPrefix}gcc"
      "HOST_CC=${buildCC}/bin/cc"
      "HOST_CFLAGS_ZLIB=-I${lib.getDev buildZlib}/include"
      "HOST_LIBS_ZLIB=-L${lib.getLib buildZlib}/lib -lz"
      "EXE=.exe"
      "TUI=0"
      "ANSI=0"
      "REPL_EDITLINE=0"
      "STRICT_CFLAGS=-std=gnu89 -Wall -Wextra -Werror -Wno-long-long -Wno-pedantic"
      "CA_BUNDLE_FILE="
      "EMBED_CA_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "LUA_BOOT_FILE="
      "PSI_CFLAGS_LUA=-I${lua55-mingw}/include"
      "PSI_LIBS_LUA=-L${lua55-mingw}/lib -llua"
      "PSI_CFLAGS_CJSON=-I${cjson-mingw}/include"
      "PSI_LIBS_CJSON=-L${cjson-mingw}/lib -lcjson"
      "PSI_CFLAGS_CURL=-I${lib.getDev curl}/include"
      "PSI_LIBS_CURL=-L${lib.getLib curl}/lib -lcurl ${tlsLibs}"
      "PSI_CFLAGS_ZLIB=-I${lib.getDev zlib}/include"
      "PSI_LIBS_ZLIB=-L${lib.getLib zlib}/lib -lz"
      "PSI_CFLAGS_ARGTABLE=-I${lib.getDev argtable}/include"
      "PSI_LIBS_ARGTABLE=-L${lib.getLib argtable}/lib -largtable3"
      "PSI_CFLAGS_EDIT="
      "PSI_LIBS_EDIT="
      "PSI_LIBS_PTHREAD=-lpthread"
    )
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp build/psi.exe $out/bin/psi.exe
    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;
  dontPatchShebangs = true;

  meta = {
    description = "psi coding agent cross-compiled to Windows via mingw-w64";
  };
}
