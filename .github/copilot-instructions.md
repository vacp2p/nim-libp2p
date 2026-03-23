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
│   │   │   ├── delay_strategy.nim  # Delay strategies for mix protocol
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
│   │   ├── mix/                # Mix protocol tests
│   │   │   ├── component/      # Component-level tests
│   │   │   ├── test_serialization.nim
│   │   │   ├── test_sphinx.nim
│   │   │   └── utils.nim       # Test utilities for mix protocol
│   ├── integration/            # Integration tests (WebSocket, AutoTLS, peer ID auth)
│   └── interop/                # Cross-implementation interoperability tests
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
- Use `{.push raises: [].}` to explicitly declare exception safety for modules and procedures.
- Use `logScope` to define logging topics for modules.
- Use `export` to re-export imported symbols when building public APIs.

### Error Handling
- Define custom exception types inheriting from `CatchableError` (e.g., `LPError`).
- Use `toException` functions to convert strings or cstrings into exception objects.
- Use `debug` and `trace` logging levels to report errors in asynchronous operations without aborting.

### Protocols
- Define protocols as objects inheriting from `LPProtocol`.
- Use `readLp` and `writeLp` for length-prefixed message handling.
- Implement reusable protocol handlers (e.g., `EchoProtocol`) for testing and debugging.

### Testing
- Organize tests to mirror the source structure.
- Use `suite` blocks to group related tests.
- Add component tests for protocol-specific behaviors (e.g., `Mix Protocol - Message Delivery`).
- Add serialization tests to validate input size constraints and error handling.

### Mix Protocol
- Use `DelayStrategy` objects to configure message delays in mix networks.
  - Example: `FixedDelayStrategy` for constant delays.
- Test tampering scenarios to validate MAC integrity (e.g., `tampered Beta invalidates MAC`).

---

## Compiler Configuration

- Treat warnings and hints as errors for stricter code quality:
  - `switch("warningAsError", "UnusedImport:on")`
  - `switch("hintAsError", "DuplicateModuleImport:on")`
- Use `--mm:refc` for memory management.
- Enable `nimRawSetjmp` on Windows (non-VC++ toolchains) to avoid stack corruption with exceptions.
