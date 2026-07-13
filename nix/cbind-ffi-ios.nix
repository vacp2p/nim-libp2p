{ pkgs
, src
, targetName
, sdk
, platformName
, targetTriple
, nimCpu ? "arm64"
, minVersion ? "13.0"
}:

let
  deps = import ./deps.nix { inherit pkgs; };
  cbindDeps = import ./cbind-deps.nix { inherit pkgs; };

  # nat_traversal is copied into the build directory because its vendored C
  # archives need to be rebuilt with the iOS toolchain.
  depsWithoutWritable = builtins.removeAttrs deps [ "nat_traversal" ];

  pathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p}") (builtins.attrValues depsWithoutWritable));

  cbindPathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p}") (builtins.attrValues cbindDeps));

  minVersionFlag =
    if sdk == "iphonesimulator"
    then "-mios-simulator-version-min=${minVersion}"
    else "-miphoneos-version-min=${minVersion}";

  tinycborVendor = "${cbindDeps.ffi}/ffi/codegen/templates/cpp/vendor/tinycbor";
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-cbind-ffi-ios-${targetName}";
  version = "dev";

  inherit src;

  nativeBuildInputs = [
    pkgs.nim-2_2
    pkgs.git
    pkgs.nimble
    pkgs.gnumake
    pkgs.which
    pkgs.file
  ];

  # iOS SDKs come from Xcode on the host macOS runner, not from nixpkgs.
  # The GitHub workflow disables the Nix sandbox so xcrun can access them.
  __noChroot = true;

  # iOS Mach-O files are target artifacts; host fixup/patchelf would be wrong.
  dontFixup = true;

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    if [ ! -x /usr/bin/xcrun ]; then
      echo "xcrun is required; build iOS targets on macOS with Xcode installed" >&2
      exit 1
    fi

    export IOS_SDK_NAME=${sdk}
    export IOS_SDK_PATH="$(/usr/bin/xcrun --sdk "$IOS_SDK_NAME" --show-sdk-path)"
    export IOS_TARGET_TRIPLE=${targetTriple}
    export IOS_MIN_VERSION_FLAG=${minVersionFlag}

    TOOLCHAIN=$TMPDIR/ios-toolchain
    mkdir -p build $NIMCACHE "$TOOLCHAIN"

    cat > "$TOOLCHAIN/clang" <<'EOF'
#!${pkgs.bash}/bin/bash
exec /usr/bin/xcrun --sdk "$IOS_SDK_NAME" clang \
  -target "$IOS_TARGET_TRIPLE" \
  -isysroot "$IOS_SDK_PATH" \
  "$IOS_MIN_VERSION_FLAG" \
  "$@"
EOF
    cat > "$TOOLCHAIN/clang++" <<'EOF'
#!${pkgs.bash}/bin/bash
exec /usr/bin/xcrun --sdk "$IOS_SDK_NAME" clang++ \
  -target "$IOS_TARGET_TRIPLE" \
  -isysroot "$IOS_SDK_PATH" \
  "$IOS_MIN_VERSION_FLAG" \
  "$@"
EOF
    cat > "$TOOLCHAIN/ar" <<'EOF'
#!${pkgs.bash}/bin/bash
exec /usr/bin/xcrun --sdk "$IOS_SDK_NAME" ar "$@"
EOF
    cat > "$TOOLCHAIN/ranlib" <<'EOF'
#!${pkgs.bash}/bin/bash
exec /usr/bin/xcrun --sdk "$IOS_SDK_NAME" ranlib "$@"
EOF
    ln -s "$TOOLCHAIN/ar" "$TOOLCHAIN/llvm-ar"
    ln -s "$TOOLCHAIN/ranlib" "$TOOLCHAIN/llvm-ranlib"
    chmod +x "$TOOLCHAIN"/clang "$TOOLCHAIN"/clang++ "$TOOLCHAIN"/ar "$TOOLCHAIN"/ranlib

    export PATH=$TOOLCHAIN:$PATH
    export CC=$TOOLCHAIN/clang
    export CXX=$TOOLCHAIN/clang++
    export AR=$TOOLCHAIN/ar
    export RANLIB=$TOOLCHAIN/ranlib

    echo "== Preparing writable dependency copies for iOS ${targetName} =="
    NAT_PKG=$TMPDIR/nat_traversal
    cp -r ${deps.nat_traversal} $NAT_PKG
    chmod -R +w $NAT_PKG

    echo "== Building nat_traversal vendored C libs for iOS ${targetName} =="
    make -C "$NAT_PKG/vendor/miniupnp/miniupnpc" \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="-Os -fPIC -D__APPLE__ -D_DARWIN_C_SOURCE" \
      build/libminiupnpc.a

    make -C "$NAT_PKG/vendor/libnatpmp-upstream" \
      CC="$CC" AR="$AR" RANLIB="$RANLIB" \
      CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" \
      libnatpmp.a

    # ffiThreadExitTimeoutMs: bound the FFI thread's graceful-shutdown wait; the
    # 1500ms default is too tight for libp2pDestroy's switch.stop() over many conns.
    commonArgs="--noNimblePath ${cbindPathArgs} ${pathArgs} --path:$NAT_PKG \
      --os:ios --cpu:${nimCpu} --cc:clang \
      --clang.path:$TOOLCHAIN \
      --clang.exe:clang --clang.linkerexe:clang++ \
      --passC:-fPIC --passC:-D_DARWIN_C_SOURCE \
      --passL:-lc++ \
      --threads:on --opt:size --noMain --mm:refc --d:metrics \
      -d:ffiThreadExitTimeoutMs=5000 \
      --nimMainPrefix:liblibp2p --nimcache:$NIMCACHE"

    echo "== Building iOS FFI library (dynamic/shared) for ${targetName} =="
    nim c $commonArgs --app:lib --out:build/liblibp2p.dylib cbind/libp2p_ffi.nim

    echo "== Building iOS FFI library (static) for ${targetName} =="
    nim c $commonArgs --app:staticlib --out:build/liblibp2p.a cbind/libp2p_ffi.nim

    echo "== Generating C bindings =="
    nim c $commonArgs --app:lib -d:ffiGenBindings -d:targetLang=c \
      -d:ffiOutputDir=cbind/c_bindings -d:ffiSrcPath=libp2p_ffi.nim \
      -o:/dev/null cbind/libp2p_ffi.nim

    echo "== Generating CDDL schema =="
    nim c $commonArgs --app:lib -d:ffiGenBindings -d:targetLang=cddl \
      -d:ffiOutputDir=cbind/cddl_bindings -d:ffiSrcPath=libp2p_ffi.nim \
      -o:/dev/null cbind/libp2p_ffi.nim

    mkdir -p cbind/c_bindings/tinycbor
    cp ${tinycborVendor}/* cbind/c_bindings/tinycbor/

    echo "== Compiling iOS C check harness for ${targetName} =="
    mkdir -p build/check-objects
    "$CC" -std=c11 -fPIE -pthread \
      -I cbind/c_bindings -I cbind/c_bindings/tinycbor \
      -c cbind/examples/libp2p_ffi_mobile_check.c \
      -o build/check-objects/libp2p_ffi_ios_check.o
    for src in cbind/c_bindings/tinycbor/*.c; do
      obj=build/check-objects/$(basename "$src" .c).o
      "$CC" -std=c11 -fPIE -I cbind/c_bindings/tinycbor -c "$src" -o "$obj"
    done
    "$CXX" -fPIE -pthread \
      build/check-objects/*.o build/liblibp2p.dylib \
      -lc++ \
      -o build/libp2p_ffi_ios_check

    /usr/bin/xcrun --sdk "$IOS_SDK_NAME" otool -l build/liblibp2p.dylib > build/liblibp2p.dylib.otool
    /usr/bin/xcrun --sdk "$IOS_SDK_NAME" otool -l build/libp2p_ffi_ios_check > build/libp2p_ffi_ios_check.otool
    /usr/bin/xcrun --sdk "$IOS_SDK_NAME" lipo -info build/liblibp2p.dylib > build/liblibp2p.dylib.lipo
    /usr/bin/xcrun --sdk "$IOS_SDK_NAME" lipo -info build/liblibp2p.a > build/liblibp2p.a.lipo
    grep -q "platform ${platformName}" build/liblibp2p.dylib.otool
    grep -q "arm64" build/liblibp2p.dylib.lipo
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include $out/bin $out/nix-support

    cp build/liblibp2p.dylib $out/lib/
    cp build/liblibp2p.a     $out/lib/
    cp $NAT_PKG/vendor/miniupnp/miniupnpc/build/libminiupnpc.a $out/lib/
    cp $NAT_PKG/vendor/libnatpmp-upstream/libnatpmp.a          $out/lib/

    cp cbind/c_bindings/*.h $out/include/
    cp -r cbind/c_bindings/tinycbor $out/include/
    cp -r cbind/cddl_bindings $out/include/

    cp build/libp2p_ffi_ios_check $out/bin/
    cp build/*.otool build/*.lipo $out/nix-support/

    printf '%s\n' \
      "target=${targetName}" \
      "sdk=${sdk}" \
      "platform=${platformName}" \
      "min_version=${minVersion}" \
      "target_triple=${targetTriple}" \
      "nim_cpu=${nimCpu}" \
      > $out/nix-support/ios-target
  '';

  meta = with pkgs.lib; {
    description = "iOS ${targetName} C ABI build of nim-libp2p libp2p_ffi";
    platforms = platforms.darwin;
  };
}
