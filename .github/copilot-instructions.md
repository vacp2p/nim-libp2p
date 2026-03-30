# nim-libp2p Coding Agent Instructions

## Project Overview

**nim-libp2p** is a native Nim implementation of the [libp2p](https://libp2p.io) peer-to-peer networking stack. It is used in production by [Nimbus (Ethereum client)](https://github.com/status-im/nimbus-eth2) and other projects.

- **Language**: Nim (see `libp2p.nimble` and `.github/workflows/ci.yml` for currently supported versions)
- **License**: Apache 2.0 OR MIT
- **Version**: 1.15.3
- **Author**: Status Research & Development GmbH

---

## Repository Layout

```
nim-libp2p/
├── libp2p/           # Main source code
│   ├── switch.nim              # Core: manages connections, protocols, transports
│   ├── standard_switch.nim     # Default switch implementation
│   ├── builders.nim            # Builder pattern for switches
│   ├── peerid.nim / peerinfo.nim / peerstore.nim
│   ├── multiaddress.nim / multistream.nim
│   ├── crypto/                 # Cryptographic primitives
│   ├── muxers/                 # Stream multiplexers (mplex, yamux)
│   ├── protocols/              # P2P protocols
│   │   ├── connectivity/       # AutoNAT, DCUtR, Circuit Relay
│   │   ├── pubsub/             # GossipSub, FloodSub
│   │   ├── kademlia/           # Kademlia DHT
│   │   ├── mix/                # Sphinx Mix Network (privacy)
│   │   ├── perf/               # Performance measurement protocol
│   │   └── secure/             # Noise, Plaintext
│   ├── transports/             # TCP, QUIC, WebSocket, Tor, Memory
│   ├── stream/                 # Stream abstractions
│   ├── autotls/                # Automatic TLS certificate management (ACME)
│   ├── services/               # Auto-relay, hole punching, wildcard resolver
│   └── utils/                  # Utilities
├── tests/
│   ├── test_all.nim            # Main test runner
│   ├── libp2p/                 # Unit tests mirroring source structure
│   ├── integration/            # Integration tests (WebSocket, AutoTLS, peer ID auth)
│   ├── interop/                # Cross-implementation interoperability tests
│   │   ├── transport-v2/       # Unified testing transport interop tests
│   │   └── transport/          # Legacy transport interop tests
├── examples/                   # Tutorial and example applications
├── cbind/                      # C/FFI bindings layer
├── docs/                       # Documentation
│   ├── development.md          # Setup and testing guide
│   ├── contributing.md         # Contribution guidelines
│   ├── compile_time_flags.md   # All compile-time flags documented
│   └── common_hurdles.md       # Known issues and fixes
├── tools/                      # Developer tools (dependency pinner, markdown runner, etc.)
├── libp2p.nim                  # Main entry point (re-exports public APIs)
├── libp2p.nimble               # Package manifest and build tasks
├── config.nims                 # Compiler configuration (warnings, style, memory)
└── Makefile                    # Top-level build targets
```

---

## Build & Test

### Setup
```sh
git clone https://github.com/vacp2p/nim-libp2p
cd nim-libp2p
nimble install -dy    # Install dependencies
# Or: nix develop     # Nix-based dev environment
```

> **Note**: nimble 0.20.1+ is required. If using `nix develop`, the nix environment may not have a sufficiently recent nimble — in that case, run `nimble install nimble` inside the nix shell to get a newer version (typically installed to `~/.nimble/bin/nimble`).

### Running Tests
```sh
# Run all unit tests
nimble test

# Run tests matching a path substring
nimble testpath quic                   # all quic tests
nimble testpath transports/test_ws     # specific test file
nimble testpath mix                    # mix protocol tests

# Run specific test suites
nimble testmultiformatexts             # MultiFormat extension tests
nimble testintegration                 # Integration tests
nimble testinterop                     # Interoperability tests
```

### Faster Iteration (bypass nimble overhead)
```sh
nim c -r tests/test_all.nim
nim c -r -d:path=quic tests/test_all.nim
nim c -r tests/tools/test_multiaddress.nim
```

### Code Formatting
```sh
nimble install nph@v0.6.1   # Install formatter (once)
nimble format
```

---

## Coding Conventions

### General
- Use `{.push raises: [].}` pragmas to enforce explicit exception handling.
- Use `chronicles` for logging, with appropriate log levels (`debug`, `trace`, `warn`, etc.).
- Prefer `async` procedures for operations involving I/O or concurrency.
- Use `quote do` for macros to improve readability and maintain hygiene.

### Error Handling
- Define custom exception types inheriting from `CatchableError` (e.g., `LPError`).
- Use `toException` functions to convert strings or cstrings into exception objects.
- Use `checkFutures` macro to handle failed futures gracefully, with optional exclusion of specific exceptions.

### Builders
- Use the `SwitchBuilder` pattern for constructing `Switch` objects with configurable components (e.g., transports, secure protocols, muxers).
- Deprecated `TransportProvider` in favor of `TransportBuilder`.

### Interoperability Testing
- Follow the [Unified Testing](https://github.com/libp2p/unified-testing) guidelines for transport interop tests.
- Use `interop/transport-v2` for updated transport testing workflows.
- Mark known errors in interop tests using regex patterns (e.g., `known-errors`).

### Compiler Configuration
- Enable strict warnings and hints as errors in `config.nims` (e.g., `UnusedImport:on`, `UnreachableCode:on`).
- Use `--mm:refc` for memory management unless testing specific branches for alternative strategies.

---

## Interoperability Testing

### Unified Testing Transport App
The `interop/transport-v2` directory contains the updated transport interop test application compatible with the [Unified Testing](https://github.com/libp2p/unified-testing) framework. This replaces the legacy `interop/transport` tests.

#### Key Features
- Supports multiple transports (e.g., TCP, QUIC, WebSocket).
- Configurable via environment variables (`TRANSPORT`, `MUXER`, `SECURE_CHANNEL`, etc.).
- Uses Redis for coordination between test nodes.

#### Example Usage
```sh
docker build -t nim-libp2p-transport-v2 -f interop/transport-v2/Dockerfile .
docker run -e TRANSPORT=tcp -e MUXER=mplex -e SECURE_CHANNEL=noise nim-libp2p-transport-v2
