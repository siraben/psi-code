{ lib
, stdenv
, gnumake
, argtable
, cjson
, curl
, cacert ? null
, lua
# OpenSSL only needed when curl uses openssl as its TLS backend
# (curl's NTLM references DES_ecb_encrypt). Pass `null` when curl
# was built with mbedTLS / wolfssl / etc.
, openssl ? null
# Extra static libs for mbedTLS-backed curl.
, mbedtls ? null
# Build-platform tools for the host embed helper.
, buildCC
, buildZlib
# cosmocc toolchain, used for bundled third_party/zlib headers.
, cosmocc
, stripDebug ? true
}:

# Static psi build for pkgsCosmo / pkgsCosmoFat.
#
# OpenBSD note: the fat APE runs on OpenBSD 7.3, but current OpenBSD
# releases enforce pinned syscall metadata that cosmocc 4.0.2 does not
# emit. Keep this derivation OS-neutral; use a native OpenBSD build for
# OpenBSD 7.9 until the toolchain grows that metadata.

stdenv.mkDerivation (finalAttrs: {
  pname = "psi-cosmocc";
  version = "0.1.0";

  src = lib.cleanSource ./..;

  nativeBuildInputs = [ gnumake ];
  depsBuildBuild = [ buildCC buildZlib ];

  # Use cosmocc's bundled zlib headers and libcosmo symbols.
  buildInputs = [
    argtable
    cjson
    curl
    lua
  ];

  enableParallelBuilding = true;
  strictDeps = true;

  # makeFlagsArray preserves multi-token values like "-L/path -lz".
  preBuild =
    let
      curlExtraLibs =
        if openssl != null
        then " -L${openssl.out}/lib -lssl -lcrypto"
        else if mbedtls != null
        then " -L${lib.getLib mbedtls}/lib -lmbedtls -lmbedx509 -lmbedcrypto"
        else "";
    in
    ''
    makeFlagsArray+=(
      "PREFIX=$out"
      "CC=${stdenv.cc.targetPrefix}cc"
      "HOST_CC=${buildCC}/bin/cc"
      "HOST_CFLAGS_ZLIB=-I${lib.getDev buildZlib}/include"
      "HOST_LIBS_ZLIB=-L${lib.getLib buildZlib}/lib -lz"
      "STATIC=1"
      "TUI=1"
      "REPL_EDITLINE=0"
      "CA_BUNDLE_FILE="
      ${lib.optionalString (cacert != null)
        ''"EMBED_CA_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"''}
      "LUA_BOOT_FILE="
      "PSI_CFLAGS_LUA=-I${lib.getDev lua}/include"
      "PSI_LIBS_LUA=-L${lib.getLib lua}/lib -llua"
      "PSI_CFLAGS_CJSON=-I${lib.getDev cjson}/include"
      "PSI_LIBS_CJSON=-L${lib.getLib cjson}/lib -lcjson"
      "PSI_CFLAGS_CURL=-I${curl.dev}/include"
      "PSI_LIBS_CURL=-L${curl.out}/lib -lcurl${curlExtraLibs}"
      # cosmocc's zlib.h remaps names to libcosmo's _Cz_* symbols.
      "PSI_CFLAGS_ZLIB=-I${cosmocc}/include/third_party/zlib"
      "PSI_LIBS_ZLIB="
      "PSI_CFLAGS_ARGTABLE=-I${lib.getDev argtable}/include"
      "PSI_LIBS_ARGTABLE=-L${lib.getLib argtable}/lib -largtable3"
      "PSI_CFLAGS_EDIT="
      "PSI_LIBS_EDIT="
    )
  '';

  installPhase = ''
    runHook preInstall
    make PREFIX=$out install
    runHook postInstall
  '';

  postFixup = lib.optionalString stripDebug ''
    ${stdenv.cc.targetPrefix}strip --strip-debug "$out/bin/psi"
  '';

  dontPatchELF = true;
  dontPatchShebangs = true;

  meta = {
    description = "psi coding agent";
    homepage = "https://github.com/siraben/psi-coding-agent";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ siraben ];
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "psi";
  };
})
