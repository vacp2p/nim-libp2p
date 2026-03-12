# nim-libp2p Repository Guide for AI Copilots

## Project Overview

**nim-libp2p** is a native Nim implementation of the [libp2p](https://libp2p.io) peer-to-peer networking stack. It's used in production by several projects including [Nimbus (Ethereum client)](https://github.com/status-im/nimbus-eth2), [logos-delivery](https://github.com/logos-messaging/logos-delivery), and [logos-storage](https://github.com/logos-storage/logos-storage-nim).

- **Language**: Nim
- **Purpose**: P2P networking library with modular architecture
- **Version**: 1.15.3 (as of last update)
- **License**: Apache 2.0 OR MIT
- **Supported Nim**: v2.0.16 and v2.2.6

## Directory Structure Overview

```
nim-libp2p/
├── .assets/                    # Logo and assets
├── .github/                    # GitHub configuration
│   └── workflows/              # CI/CD workflows (15 files)
├── cbind/                      # C bindings for libp2p
├── docs/                       # Documentation files
├── examples/                   # Example applications
├── interop/                    # Interoperability test tools
├── libp2p/                     # Main source code (26 subdirectories)
├── performance/                # Performance testing tools
├── tests/                      # Test suite
├── tools/                      # Utility scripts
├── nix/                        # Nix build configuration
├── Makefile                    # Top-level build targets
├── libp2p.nim                  # Main entry point
├── libp2p.nimble              # Package manifest
├── config.nims                 # Nim compiler configuration
├── nimdoc.cfg                  # Documentation generation config
├── codecov.yml                 # Code coverage config
├── mkdocs.yml                  # MkDocs documentation config
├── flake.lock/flake.nix        # Nix development environment
└── funding.json                # Funding information
```

## 1. Top-Level Key Files

| File | Purpose |
|------|---------|
| `libp2p.nim` | Main entry point; re-exports public APIs from libp2p/ modules |
| `libp2p.nimble` | Nimble package manifest with dependencies and tasks |
| `config.nims` | Nim compiler flags (warnings, memory management, style checks) |
| `Makefile` | Build targets: `make build`, `make clean`, `make cbind` |
| `nimdoc.cfg` | Configuration for Nim documentation generation |
| `mkdocs.yml` | Documentation site structure |
| `flake.nix` | Nix development environment with pinned dependencies |

## 2. README.md (First 100 lines)

The README provides:
- Project description as the Nim implementation of libp2p
- Links to contributing guidelines and development guide
- Installation: `nimble install libp2p`
- Supported versions: Nim v2.0.16 and v2.2.6
- Users section: Nimbus, logos-delivery, logos-storage
- Stability statement: Core is production-ready, some modules are recent
- Versioning: Semver with `.public.` procedures guaranteed compatible in MAJOR version
- License: MIT or Apache 2.0
- Modules list table with links to implementations

## 3. Main Source Code Structure (`libp2p/` - 26 directories)

### Core Components (root level .nim files)
**26 main modules** including:
- **switch.nim** - The core of libp2p; manages connections, protocols, transports
- **standard_switch.nim** - Default switch implementation
- **connmanager.nim** - Connection management
- **dialer.nim** / **dial.nim** - Initiating connections
- **peerinfo.nim** / **peerstore.nim** - Peer information storage
- **peerid.nim** - Peer identification and cryptography
- **multiaddress.nim** - Multi-protocol addressing
- **multistream.nim** - Protocol negotiation
- **builders.nim** - Builder pattern for constructing switches
- **signed_envelope.nim** - Message envelope signing
- **routing_record.nim** - Routing record handling
- **extended_peer_record.nim** - Extended peer metadata
- **observedaddrmanager.nim** - Managing observed addresses
- **wire.nim** / **vbuffer.nim** - Low-level message handling
- **varint.nim** - Variable-length integer encoding
- **multibase.nim** / **multicodec.nim** / **multihash.nim** / **cid.nim** - Multiformat standards
- **errors.nim** - Error types
- **utility.nim** / **debugutils.nim** - Utility functions
- **protobuf/** - Protobuf serialization
- **transcoder.nim** - Data transcoding

### Major Subdirectories

#### **transports/** (9 files) - Network transport layer
- `tcptransport.nim` - TCP connections
- `quictransport.nim` - QUIC protocol
- `wstransport.nim` - WebSocket connections
- `memorytransport.nim` - In-memory transport (testing)
- `tortransport.nim` - Tor transport
- `transport.nim` - Base transport interface
- `memorymanager.nim` - Memory pool management
- `tls/` - TLS certificate handling for QUIC
  - `certificate.nim`, `certificate_ffi.nim`

#### **muxers/** (5 files) - Stream multiplexing
- `mplex/` - Mplex multiplexer (multi-plexing protocol)
  - `mplex.nim` - Main implementation
  - `lpchannel.nim` - Channel management
  - `coder.nim` - Message coding
- `yamux/` - Yamux multiplexer
  - `yamux.nim`
- `muxer.nim` - Base muxer interface

#### **protocols/** (60+ files) - P2P protocols
**Core protocols:**
- `identify.nim` - Identify protocol
- `ping.nim` - Ping protocol
- `protocol.nim` - Base protocol interface
- `pubsub.nim` - Publish-Subscribe base

**Connectivity protocols:**
- `connectivity/` - NAT traversal and hole punching
  - `autonat/` - Automatic NAT detection (v1)
  - `autonatv2/` - AutoNAT v2 with dial-back
  - `dcutr/` - Direct connection upgrade through relays
  - `relay/` - Circuit relay protocol for NAT traversal
    - `relay.nim`, `client.nim`, `messages.nim`, `rconn.nim`, `rtransport.nim`, `utils.nim`

**Pub/Sub protocols:**
- `pubsub/` - Pub/Sub messaging system
  - `gossipsub.nim` - GossipSub protocol (main implementation)
  - `gossipsub/` - GossipSub extensions
    - `behavior.nim`, `scoring.nim`, `types.nim`, `extensions.nim`
    - `extension_pingpong.nim`, `extension_partial_message.nim`, `extension_test.nim`
    - `partial_message.nim`, `preamblestore.nim`
  - `floodsub.nim` - Flood subscribe (simpler pub/sub)
  - `pubsub.nim` - Base pub/sub implementation
  - `bandwidth.nim`, `errors.nim`, `timedcache.nim`, `mcache.nim`, `peertable.nim`
  - `rpc/` - RPC message definitions
    - `message.nim`, `messages.nim`, `protobuf.nim`

**Discovery protocols:**
- `kademlia.nim` - Kademlia DHT protocol
- `kademlia/` - Implementation details
  - `find.nim`, `get.nim`, `put.nim`, `ping.nim`, `provider.nim`
  - `routingtable.nim`, `types.nim`, `protobuf.nim`, `kademlia_metrics.nim`
- `kademlia_discovery/` - Kademlia discovery service
  - `randomfind.nim`, `types.nim`
- `kad_disco.nim` - Kademlia discovery wrapper

**Privacy/MIX protocol:**
- `mix.nim` / `mix_protocol.nim` - Sphinx mix network for privacy
- `mix/` - Detailed implementation (25+ files)
  - `crypto.nim`, `curve25519.nim`, `sphinx.nim`
  - `mix_message.nim`, `serialization.nim`, `fragmentation.nim`
  - `entry_connection.nim`, `exit_connection.nim`, `reply_connection.nim`, `exit_layer.nim`
  - `delay_strategy.nim`, `pool.nim`, `tag_manager.nim`
  - `spam_protection.nim`, `seqno_generator.nim`
  - `multiaddr.nim`, `benchmark.nim`, `mix_node.nim`, `mix_metrics.nim`

**Performance protocol:**
- `perf/` - Performance measurement
  - `core.nim`, `client.nim`, `server.nim`

**Rendezvous protocol:**
- `rendezvous.nim` / `rendezvous/`
  - `rendezvous.nim`, `protobuf.nim`

**Security protocols:**
- `secure/`
  - `noise.nim` - Noise protocol for encryption
  - `plaintext.nim` - Plaintext security (for testing)
  - `secure.nim` - Base security protocol

#### **crypto/** (9 files) - Cryptographic operations
- `crypto.nim` - Main crypto interface (RSA, ECNIST, Ed25519, Secp256k1, ChaCha20Poly1305)
- `rsa.nim` - RSA encryption/signing
- `ecnist.nim` - NIST elliptic curves
- `secp.nim` - Secp256k1 (Bitcoin/Ethereum curves)
- `ed25519/` - Ed25519 signing
- `curve25519.nim` - Curve25519 key exchange
- `chacha20poly1305.nim` - AEAD encryption
- `hkdf.nim` - Key derivation
- `minasn1.nim` - ASN.1 parsing

#### **stream/** (5 files) - Stream abstractions
- `lpstream.nim` - Base libp2p stream interface
- `bufferstream.nim` - Buffered stream
- `chronosstream.nim` - Chronos async stream
- `connection.nim` - Connection wrapper
- `bridgestream.nim` - Stream bridging

#### **services/** (3 files) - Protocol services
- `autorelayservice.nim` - Auto relay discovery
- `hpservice.nim` - Hole punching service
- `wildcardresolverservice.nim` - DNS resolver service

#### **upgrademngrs/** (2 files) - Connection upgrade management
- `upgrade.nim` - Basic upgrade manager
- `muxedupgrade.nim` - Muxing upgrade manager

#### **autotls/** (3 files) - Automatic TLS support
- `service.nim` - AutoTLS service
- `utils.nim` - Helper functions
- `acme/` - ACME certificate generation

#### **nameresolving/** - DNS resolution support

#### **peeridauth/** - Peer ID authentication

#### **utils/** (9 files) - Utility functions
- `bytesview.nim`, `future.nim`, `heartbeat.nim`, `ipaddr.nim`
- `offsettedseq.nim`, `semaphore.nim`, `sequninit.nim`, `tablekey.nim`, `zeroqueue.nim`

#### **protobuf/** - Protocol buffer support
- `minprotobuf.nim` - Minimal protobuf implementation

## 4. Build System

### Files
- **libp2p.nimble** - Main package manifest with tasks
- **config.nims** - Compiler configuration with warning levels
- **Makefile** - Top-level build orchestration
- **nimdoc.cfg** - Documentation generation
- **flake.nix** / **flake.lock** - Nix development environment

### Build Configuration (config.nims)
```nim
# Compiler warnings treated as errors
switch("warningAsError", "BareExcept:on")
switch("warningAsError", "CaseTransition:on")
switch("warningAsError", "LockLevel:on")
# ... (15 more warning flags)

# Memory management
switch("mm", "refc")  # Reference counting (consider switching to orc in future)

# Style checks enforced
--styleCheck: usages
--styleCheck: error
```

### Nimble Tasks (libp2p.nimble)
```nimble
task test "Runs the test suite"
task testmultiformatexts "Run multiformat extensions tests"
task testintegration "Runs integration tests"
task testpath "Run tests matching a specific path"
task pin "Create a lockfile"
task install_pinned "Reads the lockfile"
task unpin "Restore global package use"
task format "Format nim code using nph"
```

### Key Dependencies (from libp2p.nimble)
- `nim >= 2.0.0`
- `nimcrypto >= 0.6.0` - Cryptography
- `dnsclient >= 0.3.0` - DNS resolution
- `bearssl >= 0.2.5` - SSL/TLS
- `chronicles >= 0.11.0` - Logging
- `chronos >= 4.0.4` - Async I/O (core dependency)
- `metrics` - Metrics collection
- `secp256k1` - Secp256k1 cryptography
- `stew >= 0.4.2` - Utility library
- `websock >= 0.2.1` - WebSocket
- `unittest2` - Testing
- `results` - Error handling
- `serialization` - Serialization support
- `nim-lsquic` - QUIC protocol (via GitHub)
- `nim-jwt` - JWT tokens (via GitHub)

### Compiler Flags (used in tests)
```nim
# libp2p-specific feature flags
-d:libp2p_autotls_support
-d:libp2p_mix_experimental_exit_is_dest
-d:libp2p_gossipsub_1_4

# Optional expensive metrics
-d:libp2p_expensive_metrics
-d:libp2p_agents_metrics -d:KnownLibP2PAgents=nimbus,lighthouse,lodestar,prysm,teku
-d:KnownLibP2PTopics=topic1,topic2,topic3

# MultiFormat extensions
-d:libp2p_multicodec_exts=<path>
-d:libp2p_multihash_exts=<path>
-d:libp2p_multiaddress_exts=<path>
-d:libp2p_multibase_exts=<path>
-d:libp2p_contentids_exts=<path>
```

## 5. Test Structure

### Test Organization (tests/ directory)
```
tests/
├── test_all.nim                          # Main test runner
├── imports.nim                           # Test imports
├── config.nims                           # Test-specific config
├── stublogger.nim                        # Logger stub
├── stubs/                                # Test mocks/stubs
├── tools/                                # Testing utilities
├── integration/                          # Integration tests
│   └── test_all.nim
├── interop/                              # Interoperability tests
│   └── (test files)
└── libp2p/                               # Unit tests mirror source
    ├── test_conn_manager.nim
    ├── test_dialer.nim
    ├── test_multistream.nim
    ├── test_name_resolve.nim
    ├── test_observed_addr_manager.nim
    ├── test_peer_id.nim
    ├── test_peer_info.nim
    ├── test_peer_store.nim
    ├── test_routing_record.nim
    ├── test_signed_envelope.nim
    ├── test_switch.nim
    ├── test_utility.nim
    ├── test_varint.nim
    ├── test_wire.nim
    ├── test_min_protobuf.nim
    │
    ├── autotls/                          # AutoTLS tests
    ├── crypto/                           # Crypto tests
    ├── discovery/                        # Discovery tests
    ├── kademlia/                         # Kademlia DHT tests
    ├── kademlia_discovery/               # Kademlia discovery tests
    ├── multiformat/                      # Multiformat (CID, Multiaddress, etc)
    ├── multiformat_exts/                 # Extension tests
    │
    ├── muxers/                           # Muxer tests
    │   ├── test_mplex.nim
    │   └── test_yamux.nim
    │
    ├── protocols/                        # Protocol tests
    │   ├── test_identify.nim
    │   ├── test_noise.nim
    │   ├── test_ping.nim
    │   ├── test_perf.nim
    │   ├── test_autonat.nim
    │   ├── test_autonat_service.nim
    │   ├── test_autonat_v2.nim
    │   ├── test_autonat_v2_service.nim
    │   ├── test_dcutr.nim
    │   ├── test_relay_v1.nim
    │   ├── test_relay_v2.nim
    │   └── pubsub/                       # Pub/Sub tests
    │       ├── test_floodsub.nim
    │       ├── test_gossipsub.nim
    │       ├── test_gossipsub_1_4.nim
    │       └── test_gossipsub_spam.nim
    │
    ├── pubsub/                           # Additional pubsub tests
    │
    ├── services/                         # Service tests
    │   ├── test_autorelayservice.nim
    │   └── test_wildcardresolverservice.nim
    │
    ├── stream/                           # Stream tests
    │   ├── test_bufferstream.nim
    │   ├── test_chronosstream.nim
    │   └── test_connection.nim
    │
    ├── transports/                       # Transport tests
    │   ├── test_tcp.nim
    │   ├── tcp_tests.nim
    │   ├── test_quic.nim
    │   ├── test_quic_stream.nim
    │   ├── test_ws.nim
    │   ├── test_memory.nim
    │   ├── test_tor.nim
    │   ├── connection_tests.nim
    │   ├── stream_tests.nim
    │   ├── basic_tests.nim
    │   ├── utils.nim
    │   └── tls/
    │       └── test_certificate.nim
    │
    ├── mix/                              # Mix protocol tests (15+ files)
    │   ├── test_multiaddr.nim
    │   ├── test_conn.nim
    │   ├── test_tag_manager.nim
    │   ├── test_spam_protection_interface.nim
    │   ├── test_crypto.nim
    │   ├── test_mix_message.nim
    │   ├── test_spam_protection_mixnode.nim
    │   ├── test_curve25519.nim
    │   ├── test_fragmentation.nim
    │   ├── test_sphinx.nim
    │   ├── test_delay_strategy.nim
    │   ├── test_serialization.nim
    │   ├── test_seq_no_generator.nim
    │   ├── test_pool.nim
    │   └── mock_mix.nim
    │
    └── utils/                            # Utility tests
```

### Running Tests
```bash
# All tests
nimble test

# Tests matching path substring
nimble testpath quic                      # Tests containing "quic"
nimble testpath transports/test_ws        # Specific test file path
nimble testpath mix                       # MIX protocol tests

# Specific suites
nimble testmultiformatexts                # MultiFormat tests
nimble testintegration                    # Integration tests

# Direct compilation (faster iteration)
nim c -r tests/test_all.nim
nim c -r -d:path=quic tests/test_all.nim
nim c -r tests/tools/test_multiaddress.nim
```

## 6. CI Configuration (.github/workflows/)

### Main Workflows (15 YAML files)

**ci.yml** - Primary continuous integration
- Tests on multiple platforms: Linux (amd64, i386), macOS (arm64), Windows (amd64)
- Linux GCC 14 variant
- Nim versions: v2.0.16, v2.2.6
- Runs: `nimble test`

**daily_*.yml** - Daily extended testing
- `daily_amd64.yml` - 64-bit testing
- `daily_i386.yml` - 32-bit testing
- `daily_common.yml` - Common suite
- `daily_nimbus.yml` - Nimbus-specific tests
- `daily_tests_no_flags.yml` - Tests without special flags

**cbindings.yml** - C bindings compilation and testing
- Builds C FFI layer
- Tests C API examples

**coverage.yml** - Code coverage reporting
- Generates coverage metrics
- Uploads to codecov

**dependencies.yml** - Dependency checks
- Validates nimble dependencies
- Checks for updates

**documentation.yml** - Docs generation
- Builds Nim documentation
- Deploys to GitHub Pages

**examples.yml** - Example validation
- Compiles and runs example programs

**interop.yml** - Interoperability tests
- Tests compatibility with other libp2p implementations
- Hole punching tests

**performance.yml** - Performance benchmarking
- Runs performance tests
- Tracks metrics

**linters.yml** - Code quality checks
- Style checking with nph (formatter)
- Code linting

**pr_lint.yml** - Pull request checks
- Basic PR validation

**auto_assign_pr.yml** - Automatic PR assignment
- Assigns reviewers to PRs

## 7. Key Configuration Files

### config.nims - Compiler Configuration
```nim
# Memory management
switch("mm", "refc")  # Reference counting

# Warning enforcement
switch("warningAsError", "BareExcept:on")
switch("warningAsError", "CaseTransition:on")
# ... 15 more warning types

# Style enforcement
--styleCheck: usages
--styleCheck: error

# Optional nimble path locking
if dirExists("nimbledeps/pkgs2"):
  switch("NimblePath", "nimbledeps/pkgs2")

# Nimble lockfile detection
include "nimble.paths"
```

### libp2p.nimble - Package Manifest
```nimble
packageName = "libp2p"
version = "1.15.3"
author = "Status Research & Development GmbH"
license = "MIT"

requires "nim >= 2.0.0"
# 15+ dependencies listed

skipDirs = @["cbind", "examples", "interop", "performance", "tests", "tools"]

# Test tasks with compiler flags
task test "Runs the test suite"
task testpath "Run tests matching path"
task format "Format code using nph"
```

### nimdoc.cfg - Documentation Configuration
- Custom HTML templates for documentation generation
- Theme switcher for public/internal API visibility
- Documentation styling

## 8. Protocols and Features Implemented

### Network Transport Layer
- **TCP** - Reliable stream transport
- **QUIC** - UDP-based multiplexed transport with TLS
- **WebSocket** - Browser-compatible transport
- **Tor** - Tor network transport
- **Memory** - In-memory transport (testing)

### Stream Multiplexing
- **Mplex** - Multi-plexing protocol for concurrent streams
- **Yamux** - Yet Another Multiplexer protocol

### Security & Encryption
- **Noise Protocol** - Modern encryption with forward secrecy
- **Plaintext** - No encryption (testing)
- **Automatic TLS** - ACME-based certificate generation
- **Signed Envelopes** - Cryptographic message signing

### Peer Discovery
- **Kademlia DHT** - Distributed hash table for peer discovery
- **Kademlia Discovery Service** - Service wrapper for DHT
- **Rendezvous Protocol** - Rendez-vous server for peer discovery

### Connectivity & NAT Traversal
- **AutoNAT v1 & v2** - Automatic NAT detection and reporting
- **Direct Connection Upgrade Through Relay (DCUtR)** - Hole punching protocol
- **Circuit Relay v1 & v2** - Relay protocol for connectivity through NAT
- **Hole Punching Service** - Auto hole punching service
- **Auto Relay Service** - Automatic relay discovery and connection

### Pub/Sub (Message Broadcasting)
- **GossipSub** - Efficient gossip-based pub/sub (main implementation)
  - GossipSub v1.1 and v1.4 support
  - Scoring and behavior management
  - Partial message support
  - Ping/Pong extensions
  - Test extensions
- **FloodSub** - Simple flood-based pub/sub (for compatibility)
- **Bandwidth Accounting** - Pub/sub bandwidth metrics
- **Message Caching** - Duplicate prevention

### Privacy & Anonymity
- **Sphinx Mix Network (MIX Protocol)** - Privacy-preserving packet routing
  - Curve25519 key exchange
  - Delay strategies
  - Packet fragmentation
  - Spam protection
  - Reply connections
  - Tag management

### Identity & Cryptography
- **Peer ID** - Unique peer identification
- **CID (Content Identifier)** - Content addressing
- **RSA, ECNIST, Ed25519, Secp256k1** - Cryptographic key types
- **ChaCha20Poly1305** - AEAD encryption
- **HKDF** - Key derivation

### Core Protocols
- **Identify** - Protocol for exchanging peer information
- **Ping** - Basic liveness checking
- **Performance Testing** - Performance measurement protocol

### Data Format Support
- **MultiAddress** - Composable network addresses
- **MultiCodec** - Codec identifiers
- **MultiHash** - Hash identifiers
- **MultiBase** - Base encoding format identifiers
- **Extension System** - Extensible multiformat support

## 9. Contributing Guidelines

Located in **docs/contributing.md**:

### Choosing Work
- Browse issues marked as "good first issue" for newcomers
- Ping core maintainers to assign issues
- Prevent duplicate work

### Code Quality
- **Development Guide**: Read `docs/development.md` to get started
- **Compile Time Flags**: Document all flags in `docs/compile_time_flags.md`
- **Common Hurdles**: Reference `docs/common_hurdles.md` for known issues
- **Small PRs**: Keep pull requests atomic and digestible
- **Code Formatting**: Use nph formatter: `nimble install nph@v0.6.1 && nimble format`

### Getting Help
- Ask questions via GitHub issues
- Connect with contributors on Discord community channel

### Core Maintainers
- @richard-ramos
- @vladopajic
- @gmelodie

### Public vs Internal API
- Procedures marked with `.public.` are backward compatible within MAJOR version
- Internal procedures can change at each MINOR version

## 10. cbind/ Directory Structure - C Bindings

**Purpose**: Expose nim-libp2p to C/C++ applications via FFI

```
cbind/
├── .gitignore
├── Makefile                    # Delegates to cbind/Makefile
├── config.nims                 # Test config for cbind
├── cbind.nimble               # Separate package for C bindings
├── libp2p.h                   # Generated C header file (16KB)
├── libp2p.nim                 # FFI wrapper implementation
├── ffi_types.nim              # C type definitions
├── types.nim                  # Binding type wrappers
├── alloc.nim                  # Memory allocation utilities
├── libp2p_thread/             # Thread management for C bindings
├── examples/
│   ├── cbindings.c            # C example using libp2p FFI
│   ├── mix.c                  # C example using MIX protocol
│   └── examples.nimble        # Examples package config
```

### cbind.nimble Tasks
```nimble
task libDynamic "Generate dynamic bindings"   # .so/.dylib/.dll
task libStatic "Generate static bindings"     # .a
task examples "Build and run C bindings examples"
```

### Generated Artifacts
- `libp2p.h` - C header with function declarations
- `build/libp2p.a` (static library) or `build/libp2p.so` (dynamic)
- Compiled C bindings: `build/cbindings`, `build/mix`

## 11. Examples Directory

**Location**: `examples/` (14 files)

Demonstrates libp2p usage:

### Tutorial Series
- **tutorial_1_connect.nim** - Basic peer connection
- **tutorial_2_customproto.nim** - Implementing custom protocols
- **tutorial_3_protobuf.nim** - Using protocol buffers
- **tutorial_4_gossipsub.nim** - Pub/Sub messaging

### Application Examples
- **helloworld.nim** - Minimal example
- **directchat.nim** - Chat application between peers (5KB)
- **circuitrelay.nim** - Relay node example (2.7KB)
- **mix_ping.nim** - MIX protocol ping example
- **hexdump.nim** - Utility for hex dumping

### Build Configuration
- **examples.nimble** - Example package manifest
- **examples_build.nim** - Build script
- **examples_run.nim** - Run script
- **README.md** - Examples documentation
- **index.md** - Documentation index

## 12. Other Directories

### docs/
- **README.md** - Documentation index
- **development.md** - Setup and testing guide
- **contributing.md** - Contributing guide
- **compile_time_flags.md** - Compiler flag documentation
- **common_hurdles.md** - Common issues and solutions
- **protocols_mix.md** - MIX protocol detailed documentation
- **protocols_mix_spam_protection.md** - Spam protection in MIX
- **interop_hole_punching.md** - Hole punching interoperability

### performance/
- Performance benchmarking and testing tools

### interop/
- Interoperability tests with other libp2p implementations

### tools/
- Utility scripts (e.g., dependency generation, testing tools)

### nix/
- Nix flake configuration for reproducible builds

## Development Quick Start

### Setup
```bash
git clone https://github.com/vacp2p/nim-libp2p
cd nim-libp2p
nimble install -dy
# Or use: nix develop
```

### Running Tests
```bash
nimble test                    # Run all tests
nimble testpath quic          # Run specific test category
nimble testmultiformatexts    # MultiFormat extension tests
nimble testintegration        # Integration tests
```

### Compiling Examples
```bash
nim c -r examples/helloworld.nim
nim c -r examples/directchat.nim
```

### Code Formatting
```bash
nimble install nph@v0.6.1
nimble format
```

### Logging
```bash
nim c -r -d:chronicles_log_level=debug examples/helloworld.nim
nim c -r -d:chronicles_enabled_topics:switch:TRACE,quictransport:INFO examples/helloworld.nim
```

## Key Implementation Details

### Async Model
- Uses **chronos** (https://github.com/status-im/nim-chronos) for async I/O
- Non-blocking event loop for concurrent operations

### Memory Management
- Reference counting (refc) - can consider ORC in future
- `--mm:refc` configured in config.nims

### Error Handling
- Uses `results` library for Result types
- Custom error types in `libp2p/errors.nim`

### Logging
- **chronicles** library for structured logging
- Compile-time log level configuration
- Per-topic log level control

### Metrics
- Optional expensive metrics with `-d:libp2p_expensive_metrics`
- Per-peer metrics support
- Known agents tracking for metrics filtering

### Versioning
- Semver with `.public.` API stability guarantee
- Public APIs guaranteed compatible within MAJOR version
- Internal APIs can change in MINOR version

## Common File Patterns

### Module Organization
- Each major feature has a subdirectory under `libp2p/`
- Base interfaces typically in root or shared subdirectory
- Implementation details in subdirectories
- Tests mirror source structure under `tests/libp2p/`

### Test Files
- Named `test_*.nim` for unit tests
- Located in `tests/libp2p/` directory paralleling source
- Run via `test_all.nim` main runner
- Can be compiled and run directly: `nim c -r tests/file.nim`

### Protocol Implementation
- Base class in `protocols/protocol.nim`
- Protocol-specific implementation in subdirectory or single file
- Tests in `tests/libp2p/protocols/`

### Transport Implementation
- Base class in `transports/transport.nim`
- Each transport (TCP, QUIC, WS, Tor) as separate file or subdirectory
- Memory/in-memory transport for testing

## References & Links

- **Main Docs**: https://vacp2p.github.io/nim-libp2p/docs/
- **libp2p Spec**: https://github.com/libp2p/specs
- **libp2p.io**: https://libp2p.io
- **Chronos**: https://github.com/status-im/nim-chronos
- **Nim Language**: https://nim-lang.org/
- **Community Discord**: https://discord.com/channels/1204447718093750272/1351621032263417946

