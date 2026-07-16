# Android Mobile Builds For libp2p

`cbind/libp2p.nim` is the supported C ABI target for mobile builds.

## Supported Targets

The Android build uses Android API 23 by default and builds with the NDK clang
toolchain from Nix:

| Android ABI | Nim CPU | C compiler |
| --- | --- | --- |
| `arm64-v8a` | `arm64` | `aarch64-linux-android23-clang` |
| `x86_64` | `amd64` | `x86_64-linux-android23-clang` |

The Nix derivation currently pins Android NDK `27.2.12479018` through
`androidenv.composeAndroidPackages` and uses the same Android clang for
Nim-generated C code and the C check harness.

## Build Commands

Build a single ABI:

```sh
nix build .#cbind-ffi-android-arm64-v8a
nix build .#cbind-ffi-android-x86_64
```

Build both ABI layouts in one output:

```sh
nix build .#cbind-ffi-android
```

The host C ABI package remains available as:

```sh
nix build .#cbind
```

## Artifact Layout

Single-ABI outputs are flat:

```text
result/
  bin/libp2p_android_check
  include/libp2p.h
  include/nim_ffi_cbor.h
  include/nim_ffi_prelude.h
  include/tinycbor/...
  include/cddl_bindings/libp2p.cddl
  lib/liblibp2p.so
  lib/liblibp2p.a
  lib/libc++_shared.so
  nix-support/android-target
```

The aggregate output nests the same layout by ABI:

```text
result/android/arm64-v8a/...
result/android/x86_64/...
```

`liblibp2p.so` and `liblibp2p.a` intentionally keep the same naming as the host
`cbind` package.

## Downstream Linking Notes

Use the generated high-level C helpers in `include/libp2p.h`:

- `libp2p_ctx_create`
- `libp2p_ctx_start`
- `libp2p_ctx_stop`
- `libp2p_ctx_destroy`

The generated header uses TinyCBOR for request and response encoding. The Nix
output installs the required TinyCBOR headers and C sources under
`include/tinycbor`. Downstream C or C++ code that calls the generated helper
functions should compile those TinyCBOR `.c` files into the app or a support
library.

For shared-library linking, package the matching ABI's `lib/liblibp2p.so` and
`lib/libc++_shared.so` with the Android application and load them through the
normal Android native library path. For static linking, link `lib/liblibp2p.a`
together with the Android C++ runtime selected by your application.

## Android Check Harness

The Nix Android derivation compiles `cbind/examples/libp2p_mobile_check.c`
for each ABI. The harness includes the generated nim-ffi C header, creates a
default TCP/Yamux node, starts it, stops it, destroys the context, and fails on
callback errors or timeouts.

The derivation only compiles and links the harness. To run it on a device or
emulator, build the ABI matching the device and push the shared library and
check binary:

```sh
nix build .#cbind-ffi-android-arm64-v8a

adb shell 'mkdir -p /data/local/tmp/nim-libp2p'
adb push result/lib/liblibp2p.so /data/local/tmp/nim-libp2p/
adb push result/bin/libp2p_android_check /data/local/tmp/nim-libp2p/
adb shell 'cd /data/local/tmp/nim-libp2p && chmod 755 libp2p_android_check && LD_LIBRARY_PATH=. ./libp2p_android_check'
```

For an x86_64 emulator, replace the build command with:

```sh
nix build .#cbind-ffi-android-x86_64
```

## CI Coverage

`.github/workflows/mobile_android.yml` builds both Android ABI packages and
checks that each output contains:

- shared and static `liblibp2p` libraries
- Android `libc++_shared.so` runtime for the shared object
- generated C headers and CDDL
- TinyCBOR headers used by the generated C helper layer
- the linked Android check executable
- Android ELF machine headers matching the selected ABI
