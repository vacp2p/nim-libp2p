# iOS Mobile Builds For libp2p_ffi

`cbind/libp2p_ffi.nim` is the supported C ABI target for iOS builds. The legacy
`cbind/libp2p.nim` target is not extended for iOS.

## Supported Targets

The iOS build targets iOS 13.0 or newer by default and uses SDKs from an
installed Xcode bundle:

| Target | Nim CPU | SDK | Clang target |
| --- | --- | --- | --- |
| iOS device `arm64` | `arm64` | `iphoneos` | `arm64-apple-ios13.0` |
| iOS simulator `arm64` | `arm64` | `iphonesimulator` | `arm64-apple-ios13.0-simulator` |

These targets must be built on macOS with Xcode installed. They are not exposed
on Linux Nix hosts because the iPhoneOS and iPhoneSimulator SDKs are provided by
Xcode, not by nixpkgs.

## Build Commands

Build a single target on macOS:

```sh
nix build .#cbind-ffi-ios-arm64
nix build .#cbind-ffi-ios-simulator-arm64
```

Build both iOS layouts in one output:

```sh
nix build .#cbind-ffi-ios
```

If your Nix installation uses sandboxing on macOS, disable it for this build so
the derivation can access the host Xcode bundle and SDKs:

```sh
nix --extra-experimental-features "nix-command flakes" \
  --option sandbox false \
  build .#cbind-ffi-ios-arm64
```

## Artifact Layout

Single-target outputs are flat:

```text
result/
  bin/libp2p_ffi_ios_check
  include/libp2p.h
  include/nim_ffi_cbor.h
  include/nim_ffi_prelude.h
  include/tinycbor/...
  include/cddl_bindings/libp2p.cddl
  lib/liblibp2p.dylib
  lib/liblibp2p.a
  lib/libminiupnpc.a
  lib/libnatpmp.a
  nix-support/ios-target
```

The aggregate output nests the same layout by target:

```text
result/ios/arm64/...
result/ios/simulator-arm64/...
```

`liblibp2p.dylib` and `liblibp2p.a` intentionally keep the same naming as the
host `cbind-ffi` package.

## Downstream Linking Notes

Use the generated high-level C helpers in `include/libp2p.h`:

- `libp2p_ctx_create`
- `libp2p_ctx_start`
- `libp2p_ctx_stop`
- `libp2p_ctx_destroy`

The generated header uses TinyCBOR for request and response encoding. The Nix
output installs the required TinyCBOR headers and C sources under
`include/tinycbor`. Downstream C, C++, Objective-C, or Swift wrapper code that
calls the generated helper functions should compile those TinyCBOR `.c` files
into the app or a support library.

For shared-library linking, package the matching target's `lib/liblibp2p.dylib`
with the iOS application using the normal Xcode embedding/signing flow. For
static linking, link `lib/liblibp2p.a` together with `lib/libminiupnpc.a`,
`lib/libnatpmp.a`, and the C++ runtime selected by the application.

## Dependency Notes

The iOS derivation uses a writable copy of `nat_traversal` so its vendored
`miniupnpc` and `libnatpmp` archives can be rebuilt with the selected iOS SDK
and clang target.

## iOS Check Harness

The Nix iOS derivation compiles `cbind/examples/libp2p_ffi_mobile_check.c` for
each target. The harness includes the generated nim-ffi C header, creates a
default TCP/Yamux node, starts it, stops it, destroys the context, and fails on
callback errors or timeouts.

The derivation only compiles and links the harness. It does not run the harness
on a simulator or physical device.

## CI Coverage

`.github/workflows/mobile_ios.yml` runs on macOS and builds both iOS packages.
The workflow checks that each output contains:

- shared and static `liblibp2p` libraries
- generated C headers and CDDL
- TinyCBOR headers used by the generated C helper layer
- the linked iOS check executable
- Mach-O platform metadata matching the selected SDK
- `arm64` architecture metadata for the dynamic library, static library,
  and check executable
