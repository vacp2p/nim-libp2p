# Produces a writable copy of nat_traversal with the vendored miniupnpc /
# libnatpmp static archives built in-tree at the exact paths the nat_traversal
# Nim wrappers reference via `{.passL.}` (which resolve relative to
# `currentSourcePath`, i.e. next to the wrapper sources).
#
# The fetched nat_traversal source lives in the read-only nix store, so we
# can't `make` inside it; producing the archives in a separate derivation
# output isn't enough either, because the wrapper's passL paths point at the
# nat_traversal source dir, not at our output. So we mirror the whole tree
# into $out with archives baked in, and use $out as the `--path:nat_traversal`
# in the cbind build.
#
# This mirrors the non-Windows recipe in the top-level Makefile (CFLAGS, output
# paths); nix only ever builds for unix.
{ pkgs, natSrc }:

pkgs.stdenv.mkDerivation {
  pname = "nat-traversal-with-clibs";
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

    # Mirror the whole tree (sources + freshly built archives) so the
    # wrappers' currentSourcePath-relative passL paths resolve under $out.
    cp -r . $out
    # Fail loud if either archive isn't at the path the wrappers expect.
    test -f $out/vendor/miniupnp/miniupnpc/build/libminiupnpc.a
    test -f $out/vendor/libnatpmp-upstream/libnatpmp.a

    runHook postInstall
  '';
}
