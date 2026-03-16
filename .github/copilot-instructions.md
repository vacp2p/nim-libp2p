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
- Use `raises: []` pragmas to explicitly declare exception safety for procedures where applicable.
- Use `{.push public.}` and `{.push raises: [].}` pragmas at the top of modules to enforce consistent visibility and exception handling.
- Use `logScope` to define logging topics for modules (e.g., `logScope: topics = "libp2p switch"`).
- Avoid using deprecated constructs; replace them with updated alternatives (e.g., use `TransportBuilder` instead of `TransportProvider`).

### Compiler Configuration
- The following warnings are treated as errors in `config.nims`:
  - `BareExcept`
  - `CaseTransition`
  - `CStringConv`
  - `ImplicitDefaultValue`
  - `LockLevel`
  - `ObservableStores`
  - `ResultShadowed`
  - `UnreachableCode`
  - `UnreachableElse`
  - `UnusedImport`
  - `UseBase`
- The following hints are treated as errors in `config.nims`:
  - `ConvFromXtoItselfNotNeeded`
  - `DuplicateModuleImport`
  - `XCannotRaiseY`

### Testing
- Unit tests should mirror the source structure and be placed in the `tests/libp2p/` directory.
- Integration tests should be placed in the `tests/integration/` directory and focus on testing interactions between components (e.g., WebSocket, AutoTLS, peer ID authentication).
- Interoperability tests with other implementations should be placed in the `tests/interop/` directory.

### Modules
- Use `LPError` as the base exception type for libp2p-specific errors.
- Use `SwitchBuilder` for constructing `Switch` objects with a fluent interface.
- Use `MultiAddress` for handling multi-address representations.
- Use `shortLog` for compact string representations of `PeerId` objects in logs.
- Use `checkFutures` macro to handle sequences of futures, with optional exclusion of specific exceptions.

### Logging
- Use `chronicles` for structured logging.
- Use `debug` for non-critical issues and `trace` for detailed exception messages and stack traces.

---

## Contribution Guidelines

Refer to `docs/contributing.md` for detailed contribution guidelines, including code style, commit message format, and pull request process.
