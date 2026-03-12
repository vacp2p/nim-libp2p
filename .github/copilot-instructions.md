# nim-libp2p Coding Agent Instructions

## Project Overview

**nim-libp2p** is a native Nim implementation of the [libp2p](https://libp2p.io) peer-to-peer networking stack. It is used in production by [Nimbus (Ethereum client)](https://github.com/status-im/nimbus-eth2) and other projects.

- **Language**: Nim ( see `libp2p.nimble` and `.github/workflows/ci.yml` for currently supported versions)
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
│   │   └── secure/             # Noise, Plaintext
│   ├── transports/             # TCP, QUIC, WebSocket, Tor, Memory
│   ├── stream/                 # Stream abstractions
│   ├── services/               # Auto-relay, hole punching, wildcard resolver
│   └── utils/                  # Utilities
├── tests/
│   ├── test_all.nim            # Main test runner
│   └── libp2p/                 # Unit tests mirroring source structure
├── examples/                   # Tutorial and example applications
├── cbind/                      # C/FFI bindings layer
├── docs/                       # Documentation
│   ├── development.md          # Setup and testing guide
│   ├── contributing.md         # Contribution guidelines
│   ├── compile_time_flags.md   # All compile-time flags documented
│   └── common_hurdles.md       # Known issues and fixes
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
nimble format               # Format all code
```

### Logging / Debug
```sh
nim c -r -d:chronicles_log_level=debug examples/helloworld.nim
nim c -r -d:chronicles_enabled_topics:switch:TRACE,quictransport:INFO examples/helloworld.nim
```

---

## Compiler Configuration (`config.nims`)

Warnings are treated as errors. All of the following must pass cleanly:

```nim
switch("warningAsError", "BareExcept:on")
switch("warningAsError", "CaseTransition:on")
switch("warningAsError", "CStringConv:on")
switch("warningAsError", "ImplicitDefaultValue:on")
switch("warningAsError", "LockLevel:on")
switch("warningAsError", "ObservableStores:on")
switch("warningAsError", "ResultShadowed:on")
switch("warningAsError", "UnreachableElse:on")
switch("warningAsError", "UnusedImport:on")
switch("warningAsError", "UseBase:on")
switch("hintAsError", "ConvFromXtoItselfNotNeeded:on")
switch("hintAsError", "DuplicateModuleImport:on")
--styleCheck: usages
--styleCheck: error
--mm: refc          # Reference counting (not ORC yet)
```

**Important**: The style checker enforces consistent identifier casing. Identifier names must match their declaration exactly.

---

## Compile-Time Feature Flags

These flags are used in CI and tests:

| Flag | Purpose |
|------|---------|
| `-d:libp2p_autotls_support` | Enable AutoTLS support |
| `-d:libp2p_gossipsub_1_4` | Enable GossipSub v1.4 |
| `-d:libp2p_mix_experimental_exit_is_dest` | MIX protocol: exit node is destination |
| `-d:libp2p_expensive_metrics` | Per-peer cardinality metrics |
| `-d:libp2p_agents_metrics -d:KnownLibP2PAgents=nimbus,...` | Known agent metrics |
| `-d:KnownLibP2PTopics=topic1,topic2` | GossipSub topic metrics |
| `-d:libp2p_multicodec_exts=<path>` | MultiCodec extensions file |
| `-d:libp2p_multihash_exts=<path>` | MultiHash extensions file |
| `-d:libp2p_multiaddress_exts=<path>` | MultiAddress extensions file |
| `-d:libp2p_multibase_exts=<path>` | MultiBase extensions file |
| `-d:libp2p_contentids_exts=<path>` | ContentIds extensions file |

The test runner (`libp2p.nimble`) always compiles with:
`-d:libp2p_autotls_support -d:libp2p_mix_experimental_exit_is_dest -d:libp2p_gossipsub_1_4`

---

## Key Dependencies

- **chronos** (`>= 4.0.4`) — Async I/O framework (core dependency, used everywhere)
- **chronicles** (`>= 0.11.0`) — Structured logging
- **stew** (`>= 0.4.2`) — Utility library
- **results** — Result/Option types for error handling
- **nimcrypto** — Cryptographic algorithms
- **secp256k1** — Secp256k1 curve operations
- **bearssl** — TLS/SSL
- **websock** — WebSocket transport
- **nim-lsquic** — QUIC transport (pinned to a specific GitHub commit; see `libp2p.nimble` for the exact pin)
- **unittest2** — Testing framework

---

## Code Conventions

#### `result` return
- DO NOT USE `result` for returning values.
- Use expression-based return or explicit return keyword with a value

### Async Model
- All async code uses **chronos** (`import chronos`)
- Use `async` / `await` / `Future[T]` patterns
- Async procedures return `Future[T]` or `Future[void]`
- Manually created `Futures` should specify the exceptions they raise: `Future[someType].Raising([ListOfExceptionsHere]).init()`

### Error Handling
- Use the **results** library: `Result[T, E]`, `?`, `valueOr`, `isOk`, `isErr`
- Custom error types are in `libp2p/errors.nim` (derive from `LPError`)
- Use `valueOr` over `tryGet()` when catching errors — `tryGet()` raises `ResultError[string]` which is NOT a subtype of `LPError`
- Example: use `let ma = maResult.valueOr: return err(...)` not `let ma = maResult.tryGet()`

### Logging
- Use **chronicles**: `logScope`, `trace`, `debug`, `info`, `warn`, `error`
- Example:
  ```nim
  logScope:
    topics = "switch"
  debug "Connecting to peer", peerId
  ```

### Memory Management
- Memory model: `--mm:refc` (reference counting)
- For C bindings (`cbind/`): use `createShared`/`freeShared` for cross-thread objects

### Style

#### General
- Nim identifier naming: `camelCase` for variables/procedures, `PascalCase` for types
- Style check is **strict** — naming must match declaration exactly
- No bare `except` clauses (use typed exceptions)
- No unused imports

#### Exceptions
- For new or significantly modified public `*` functions, add an explicit `{.raises.}` annotation; existing public APIs may not yet follow this consistently.
- If you must use exceptions, use specific exception types. Avoid raising or capturing `CatchableError`. Catching `CatchableError` implies that all errors are funnelled through the same exception handler.
- Do not catch `CancelledError`. By not catching, it is propagated by default. Sometimes this exception is captured and re-raised which is fine.
- Use `e` as error variable name in `except` clause like `except LPStreamEOFError as e`

#### Result
- Use explicit error-signalling types (`bool`, `Opt`, `Result`) over implicit mechanisms like exceptions or status codes
- Use `results.Opt` for optional value.
- Do not use other types like `options.Option`.

#### Status codes
- Avoid status codes

#### Binary data
- Use `byte` to denote binary data. Use `seq[byte]` for dynamic byte arrays.
- Avoid `string` for binary data. If stdlib returns strings, [convert](https://github.com/status-im/nim-stew/blob/76beeb769e30adc912d648c014fd95bf748fef24/stew/byteutils.nim#L141) to `seq[byte]` as early as possible

#### Converters
- Avoid using converters.

#### Finalizers
- Don't use finalizers.

#### Import, export
- Use specific imports. Avoid `include`.

#### Inline functions
- Avoid using explicit {.inline.} functions.

#### Integers
- Use signed integers for counting, lengths, array indexing etc.
- Use unsigned integers of specified size for interfacing with binary data, bit manipulation, low-level hardware access and similar contexts.
- Don't cast `pointer` to `int`.
- Avoid `Natural` - implicit conversion from `int` to `Natural` can raise a `Defect`

#### Macros
- Be judicious in macro usage - use more simple constructs.
- Avoid generating public API functions with macros.
- Write as much code as possible in templates, and glue together using macros

#### Memory allocation
- Prefer to use stack-based and statically sized data types in core/low-level libraries.
- Use heap allocation in glue layers.
- Avoid `alloca`.

#### Object construction
- Use `Xxx(x: 42, y: Yyy(z: 54))` style, or if type has an `init` or `new` function, `Type.init(a, b, c)`.
- Prefer that the default 0-initialization is a valid state for the type.
- Avoid using `var instance: Type` which disable several compiler diagnostics
- If a function creates a stack object, it should be called `init`. If it returns a heap object `new`

#### Functions and procedures
- Use `func` when possible. Use `proc` when side effects cannot conveniently be avoided.
- Avoid public functions and variables (`*`) that don't make up an intended part of public API.
- Use `openArray` as argument type over `seq` for traversals

#### Callbacks, closures and forward declarations
- Annotate proc type definitions and forward declarations with `{.raises: [], gcsafe.}` or specific exception types.

#### `range`
- Avoid range types.

#### `ref object` types
- Avoid ref object types, except:
- Use explicit `ref MyType` where reference semantics are needed, allowing the caller to choose where possible.

#### Variable declaration
- Use the most restrictive of `const`, `let` and `var` that the situation allows.

#### Variable initialization
- Prefer expressions to initialize variables and return values

#### Hex output
- Print hex output in lowercase. Accept upper and lower case.

#### Standard library usage
- Use the Nim standard library judiciously. Prefer smaller, separate packages that implement similar functionality, where available.
- Use the following stdlib replacements that offer safer API (allowing more issues to be detected at compile time):
```
    async -> chronos
    bitops -> stew/bitops2
    endians -> stew/endians2
    exceptions -> results
    io -> stew/io2
    sqlite -> nim-sqlite3-abi
    streams -> nim-faststreams
```

#### `stew`
- stew contains small utilities and replacements for std libraries.
- If similar libraries exist in `std` and `stew`, use [stew](https://github.com/status-im/nim-stew).

#### `discard`
- `discard` should not be used for empty body statements in tests: if used in try-except block when error is expected it is better to use `expect` instead. For callbacks, they should either raise an error because they should not be called, or, if it is indeed a noop callback, it should be written once then reused always.

#### RNG
- Do not use `newRng()`. In the nim-libp2p test files, do not use `newRng()`. Instead use `rng` template from `tests/tools/crypto.nim`
- Ignore `nim-libp2p/tests/tools/crypto.nim` (that's the definition file)

### API Stability
- Procedures marked with `.public.` pragma are backward-compatible within MAJOR versions
- Internal procedures may change at MINOR versions

### Experimental GossipSub Extensions
- Must use protobuf field numbers `> 0x200000` to force ≥4-byte tags
  (see `libp2p/protocols/pubsub/rpc/protobuf.nim`)

---

## Source Module Guide

### Core Modules
| Module | Purpose |
|--------|---------|
| `switch.nim` | Central hub: manages peers, protocols, transports |
| `standard_switch.nim` | Pre-configured Switch with sensible defaults |
| `builders.nim` | Builder API for constructing Switch instances |
| `peerid.nim` | Peer identity (cryptographic key-based) |
| `peerinfo.nim` | Metadata about a peer (addresses, protocols) |
| `peerstore.nim` | Storage and lookup of peer information |
| `multiaddress.nim` | Composable multi-protocol network addresses |
| `multistream.nim` | Protocol negotiation over streams |
| `errors.nim` | Base error type `LPError` |

### Transport Layer (`transports/`)
| Transport | File |
|-----------|------|
| TCP | `tcptransport.nim` |
| QUIC | `quictransport.nim` |
| WebSocket | `wstransport.nim` |
| Tor | `tortransport.nim` |
| In-memory (testing) | `memorytransport.nim` |

### Muxers (`muxers/`)
- `mplex/mplex.nim` — Mplex multiplexer
- `yamux/yamux.nim` — Yamux multiplexer

### Security (`protocols/secure/`)
- `noise.nim` — Noise protocol (primary)
- `plaintext.nim` — No encryption (testing only)

### Pub/Sub (`protocols/pubsub/`)
- `gossipsub.nim` — GossipSub (primary pub/sub, used in production)
- `floodsub.nim` — FloodSub (simpler, for compatibility)
- `gossipsub/` — Extensions: scoring, behavior, partial messages, ping-pong

### Connectivity (`protocols/connectivity/`)
- `autonat/` — AutoNAT v1 (NAT detection)
- `autonatv2/` — AutoNAT v2 (dial-back)
- `dcutr/` — Direct Connection Upgrade Through Relay (hole punching)
- `relay/` — Circuit Relay v1/v2

### Discovery (`protocols/`)
- `kademlia.nim` + `kademlia/` — Kademlia DHT
- `kad_disco.nim` + `kademlia_discovery/` — Kademlia-based peer discovery
- `rendezvous.nim` — Rendezvous server protocol

### Privacy (`protocols/mix/`)
- Sphinx mix network for privacy-preserving message routing
- Curve25519, fragmentation, delay strategies, spam protection

### Services (`services/`)
- `autorelayservice.nim` — Automatic relay selection and connection
- `hpservice.nim` — Hole punching service
- `wildcardresolverservice.nim` — DNS wildcard resolver

---

## Test Conventions

- Tests are in `tests/libp2p/` mirroring source structure
- Test files named `test_*.nim`
- Main runner: `tests/test_all.nim`
- Use `unittest2` framework
- Tests can be compiled and run directly: `nim c -r tests/libp2p/test_switch.nim`
- Path filtering: `-d:path=<substring>` selects test files whose path contains the substring

### Test Stubs and Utilities
- `tests/stubs/` — Mock objects
- `tests/stublogger.nim` — Logger stub for tests
- `tests/imports.nim` — Common test imports

---

## C Bindings (`cbind/`)

The `cbind/` directory contains the C/FFI layer for using nim-libp2p from C/C++:

- `libp2p.nim` — FFI function implementations (exported with `{.exportc.}`)
- `libp2p.h` — Generated C header
- `ffi_types.nim` — C-compatible type definitions
- `alloc.nim` — Cross-thread memory allocation helpers
- `libp2p_thread/` — Thread management for async operations from C
- `examples/cbindings.c`, `examples/mix.c` — C usage examples

```sh
cd cbind
nimble libDynamic    # Build .so/.dylib/.dll
nimble libStatic     # Build .a
nimble examples      # Build and run C examples
```

**cbind conventions**:
- Validate all `cstring` pointer parameters for `nil` before use; call the callback with `RET_ERR` if nil
- Use `valueOr` (not `tryGet()`) when converting cstring multiaddresses to `MultiAddress` objects

---

## CI Workflows (`.github/workflows/`)

| Workflow | Description |
|----------|-------------|
| `ci.yml` | Main CI: Linux (amd64/i386), macOS (arm64), Windows; Nim v2.0.16 & v2.2.6 |
| `daily_amd64.yml` / `daily_i386.yml` | Extended daily tests |
| `daily_nimbus.yml` | Nimbus-specific test matrix |
| `daily_tests_no_flags.yml` | Tests without experimental flags |
| `cbindings.yml` | C bindings compilation and tests |
| `coverage.yml` | Code coverage (uploads to codecov) |
| `linters.yml` | nph formatting checks |
| `examples.yml` | Example compilation/execution |
| `interop.yml` | Cross-implementation interoperability |
| `performance.yml` | Performance benchmarks |
| `documentation.yml` | Docs generation and deployment |

---

## Common Issues and Fixes

### `Error: undeclared identifier` when compiling
This usually means stale nimble packages. Fix:
1. Remove `~/.nimble`
2. Re-install Nim freshly
3. `nimble install nimble` (get latest nimble)
4. `nimble install -dy` in the project

### Formatting errors in CI
Run `nimble format` locally before pushing. The `linters.yml` CI workflow checks formatting with `nph`.

### Windows-specific
`--define:nimRawSetjmp` is set on Windows (non-MSVC) to avoid stack corruption with SEH and exceptions.

### QUIC transport
Uses `nim-lsquic` (pinned GitHub commit). May require extra system dependencies for building.

---

## Documentation

- **API docs**: https://vacp2p.github.io/nim-libp2p/docs/
- **libp2p spec**: https://github.com/libp2p/specs
- **Chronos async**: https://github.com/status-im/nim-chronos
- **Chronicles logging**: https://github.com/status-im/nim-chronicles
- **Community Discord**: https://discord.com/channels/1204447718093750272/1351621032263417946

---

## Quick Reference

```sh
# Build (check compilation)
nim c libp2p.nim

# Run all tests
nimble test

# Run specific test
nimble testpath switch          # tests matching "switch"
nimble testpath protocols/pubsub

# Format code (required before PR)
nimble format

# Install/lock dependencies
nimble install -dy              # fresh install
nimble pin                      # create lockfile
nimble install_pinned           # install from lockfile
```
