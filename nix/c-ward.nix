{ lib
, rustPlatform
, fetchCrate
}:

rustPlatform.buildRustPackage rec {
  pname = "c-ward";
  version = "0.22.3";

  # c-gull is the published libc facade from the c-ward repository, and the
  # crates.io archive includes Cargo.lock.
  src = fetchCrate {
    pname = "c-gull";
    inherit version;
    hash = "sha256-tK7yCt2G92IKOxb+64jSnO41t7C9YHAvreJKJZAjvbc=";
  };

  cargoHash = "sha256-MlmskEGJ1BA6Kzi6pbo+y1jjYsQIcoj3/TmzGfxU5dU=";
  cargoBuildType = "release";

  # c-ward and printf-compat use nightly-only Rust features. This keeps
  # the package self-contained with nixpkgs' Rust toolchain.
  env.RUSTC_BOOTSTRAP = "1";

  doCheck = false;

  postInstall = ''
    install -Dm644 README.md "$out/share/doc/c-ward/README.md"

    mkdir -p "$out/lib/rust"
    find target -path "*/${cargoBuildType}/deps/libc_gull-*.rlib" \
      -exec cp {} "$out/lib/rust/" \;
    find target -path "*/${cargoBuildType}/deps/libc_scape-*.rlib" \
      -exec cp {} "$out/lib/rust/" \;
  '';

  meta = {
    description = "Implementation of the libc ABI written in Rust";
    homepage = "https://github.com/sunfishcode/c-ward";
    license = with lib.licenses; [ asl20 mit llvm-exception ];
    platforms = lib.platforms.linux;
  };
}
