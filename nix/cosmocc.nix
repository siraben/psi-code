{ lib
, stdenv
, writeText
}:

# Smoke test — builds a hello binary with whatever stdenv is supplied.
# Designed for both `pkgs` (with `cc` overridden to cosmocc) and the
# cosmopkgs branch's pkgsCosmo / pkgsCosmoFat cross sets, where
# `stdenv.cc` is already a cosmocc-wrapped gcc that produces a static
# no-glibc artefact (an Actually-Portable Executable on cosmocc 4.x;
# a static ELF on 2.x).
#
# Deliberately depends on nothing else — no pkg-config, no extra
# buildInputs — to dodge the cross-glibc-nolibgcc bootstrap path that
# pkg-config triggers in the cosmopkgs branch's pkgsCosmo. (Without
# pkg-config, the cross stdenv only needs the cc-wrapper + cosmocc.)
#
# Going from this stub to a real psi build means vendoring lua5.4,
# argtable3, libcjson, and either replacing libcurl with mbedtls
# bindings or vendoring libcurl-with-mbedtls — each as its own
# stdenv.mkDerivation that compiles via the same `$CC`. Those are the
# leaf deps psi pulls; ncurses/libedit are skippable via the existing
# no-TUI / PSI_NO_LIBEDIT switches.

let
  hello = writeText "hello.c" ''
    #include <stdio.h>
    int main(int argc, char **argv) {
      printf("psi-cosmocc smoke test, argc=%d, host=%s\n",
             argc, "${stdenv.hostPlatform.config}");
      return 0;
    }
  '';
in
stdenv.mkDerivation {
  pname = "psi-cosmocc-hello";
  version = "0.1.0";

  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    $CC -o psi-cosmocc-hello ${hello}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp psi-cosmocc-hello $out/bin/
    runHook postInstall
  '';

  # The cc-wrapper hands us cosmocc-emitted artefacts; nixpkgs's
  # default strip / patchelf would corrupt them.
  dontStrip = true;
  dontPatchELF = true;
  dontPatchShebangs = true;

  meta = {
    description = "Static, no-glibc hello binary built via cosmocc";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
