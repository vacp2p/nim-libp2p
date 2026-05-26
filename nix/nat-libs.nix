# Builds the vendored miniupnpc / libnatpmp static archives that the
# nat_traversal Nim wrappers reference at link time.
#
# The nimble flow does this via the top-level Makefile `nat_libs` target, which
# invokes the vendored Makefiles in-place. Under nix the fetched nat_traversal
# source lives in the read-only store, so we build it in this derivation's
# writable copy and expose the .a's under $out/lib. This mirrors the non-Windows
# recipe in Makefile (CFLAGS, output paths); nix only ever builds for unix.
{ pkgs, natSrc }:

pkgs.stdenv.mkDerivation {
  pname = "nat-traversal-clibs";
  version = "dev";

  src = natSrc;

  # stdenv already provides make + a C compiler ($CC); no extra inputs needed.
  buildPhase = ''
    runHook preBuild

    # miniupnpc's unix Makefile drops the archive under build/.
    make -C vendor/miniupnp/miniupnpc \
      CC=$CC CFLAGS="-Os -fPIC" build/libminiupnpc.a

    # libnatpmp drops it at the package root.
    make -C vendor/libnatpmp-upstream \
      CC=$CC CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" \
      libnatpmp.a

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib
    cp vendor/miniupnp/miniupnpc/build/libminiupnpc.a $out/lib/
    cp vendor/libnatpmp-upstream/libnatpmp.a          $out/lib/

    runHook postInstall
  '';
}
