<h1 align="center">
  <a href="https://libp2p.io"><img width="250" src="./.assets/full-logo.svg?raw=true" alt="nim-libp2p logo" /></a>
</h1>

<h3 align="center">The Nim implementation of the libp2p Networking Stack.</h3>

<p align="center">
<a href="https://github.com/status-im/nim-libp2p/actions"><img src="https://github.com/status-im/nim-libp2p/actions/workflows/ci.yml/badge.svg" /></a>
<a href="https://codecov.io/gh/status-im/nim-libp2p"><img src="https://codecov.io/gh/status-im/nim-libp2p/branch/master/graph/badge.svg?token=UR5JRQ249W"/></a>

</p>

<p align="center">
<a href="https://opensource.org/licenses/Apache-2.0"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" /></a>
<a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" /></a>
<img src="https://img.shields.io/badge/nim-%3E%3D1.2.0-orange.svg?style=flat-square" />
</p>

## Introduction

An implementation of [libp2p](https://libp2p.io/) in [Nim](https://nim-lang.org/).

# Table of Contents
- [Background](#background)
- [Install](#install)
- [Getting Started](#getting-started)
- [Modules](#modules)
- [Users](#users)
- [Development](#development)
  - [Contribute](#contribute)
  - [Core Developers](#core-developers)
- [License](#license)

## Background
libp2p is a networking stack and library modularized out of [The IPFS Project](https://github.com/ipfs/ipfs), and bundled separately for other tools to use.

libp2p is the product of a long and arduous quest of understanding; a deep dive into the internet's network stack and the peer-to-peer protocols from the past. Building large scale peer-to-peer systems has been complex and difficult in the last 15 years and libp2p is a way to fix that. It is a "network stack", a suite of networking protocols that cleanly separates concerns and enables sophisticated applications to only use the protocols they absolutely need, without giving up interoperability and upgradeability.

libp2p grew out of IPFS, but it is built so that lots of people can use it, for lots of different projects.

- Learn more about libp2p at [**libp2p.io**](https://libp2p.io) and follow our evolving documentation efforts at [**docs.libp2p.io**](https://docs.libp2p.io).
- [Here](https://github.com/libp2p/libp2p#description) is an overview of libp2p and its implementations in other programming languages.

## Install
**Prerequisite**
- [Nim](https://nim-lang.org/install.html)
```
nimble install libp2p
```

## Getting Started
You'll find the documentation [here](https://status-im.github.io/nim-libp2p/docs/).

**Go Daemon:**
Please find the installation and usage intructions in [daemonapi.md](examples/go-daemon/daemonapi.md).

## Modules

List of packages modules implemented in nim-libp2p:

| Name                                                       | Description                                                                                                      |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Libp2p**                                                 |                                                                                                                  |
| [libp2p](libp2p/switch.nim)                                | The core of the project                                                                                          |
| [connmanager](libp2p/connmanager.nim)                      | Connection manager                                                                                               |
| [identify / push identify](libp2p/protocols/identify.nim)  | [Identify](https://docs.libp2p.io/concepts/protocols/#identify) protocol                                         |
| [ping](libp2p/protocols/ping.nim)                          | [Ping](https://docs.libp2p.io/concepts/protocols/#ping) protocol                                                 |
| [libp2p-daemon-client](libp2p/daemon/daemonapi.nim)        | [go-daemon](https://github.com/libp2p/go-libp2p-daemon) nim wrapper                                              |
| [interop-libp2p](tests/testinterop.nim)                    | Interop tests                                                                                                    |
| **Transports**                                             |                                                                                                                  |
| [libp2p-tcp](libp2p/transports/tcptransport.nim)           | TCP transport                                                                                                    |
| [libp2p-ws](libp2p/transports/wstransport.nim)             | WebSocket & WebSocket Secure transport                                                                           |
| **Secure Channels**                                        |                                                                                                                  |
| [libp2p-secio](libp2p/protocols/secure/secio.nim)          | [Secio](https://docs.libp2p.io/concepts/protocols/#secio) secure channel                                         |
| [libp2p-noise](libp2p/protocols/secure/noise.nim)          | [Noise](https://github.com/libp2p/specs/tree/master/noise) secure channel                                        |
| [libp2p-plaintext](libp2p/protocols/secure/plaintext.nim)  | [Plain Text](https://github.com/libp2p/specs/tree/master/plaintext) for development purposes                     |
| **Stream Multiplexers**                                    |                                                                                                                  |
| [libp2p-mplex](libp2p/muxers/mplex/mplex.nim)              | [MPlex](https://github.com/libp2p/specs/tree/master/mplex) multiplexer                                           |
| **Data Types**                                             |                                                                                                                  |
| [peer-id](libp2p/peerid.nim)                               | [Cryptographic identifiers](https://docs.libp2p.io/concepts/peer-id/)                                            |
| [peer-store](libp2p/peerstore.nim)                         | ["Phone book" of known peers](https://docs.libp2p.io/concepts/peer-id/#peerinfo)                                 |
| [multiaddress](libp2p/multiaddress.nim)                    | [Composable network addresses](https://github.com/multiformats/multiaddr)                                        |
| [signed envelope](libp2p/signed_envelope.nim)              | [Signed generic data container](https://github.com/libp2p/specs/blob/master/RFC/0002-signed-envelopes.md)        |
| [routing record](libp2p/routing_record.nim)                | [Signed peer dialing informations](https://github.com/libp2p/specs/blob/master/RFC/0003-routing-records.md)      |
| **Utilities**                                              |                                                                                                                  |
| [libp2p-crypto](libp2p/crypto)                             | Cryptographic backend                                                                                            |
| [libp2p-crypto-secp256k1](libp2p/crypto/secp.nim)          |                                                                                                                  |
| **Pubsub**                                                 |                                                                                                                  |
| [libp2p-pubsub](libp2p/protocols/pubsub/pubsub.nim)        | Pub-Sub generic interface                                                                                        |
| [libp2p-floodsub](libp2p/protocols/pubsub/floodsub.nim)    | FloodSub implementation                                                                                          |
| [libp2p-gossipsub](libp2p/protocols/pubsub/gossipsub.nim)  | [GossipSub](https://docs.libp2p.io/concepts/publish-subscribe/) implementation                                   |

## Users

nim-libp2p is used by:
- [Nimbus](https://github.com/status-im/nimbus-eth2), an Ethereum client
- [nwaku](https://github.com/status-im/nwaku), a decentralized messaging application
- [nim-codex](https://github.com/status-im/nim-codex), a decentralized storage application
- (open a pull request if you want to be included here)

## Development
**Clone and Install dependencies:**

```sh
git clone https://github.com/status-im/nim-libp2p
cd nim-libp2p
nimble install
```

**Run unit tests**
```sh
# run all the unit tests
nimble test
```

### Contribute

The libp2p implementation in Nim is a work in progress. We welcome contributors to help out! Specifically, you can:
- Go through the modules and **check out existing issues**. This would be especially useful for modules in active development. Some knowledge of IPFS/libp2p may be required, as well as the infrastructure behind it.
- **Perform code reviews**. Feel free to let us know if you found anything that can a) speed up the project development b) ensure better quality and c) reduce possible future bugs.
- **Add tests**. Help nim-libp2p to be more robust by adding more tests to the [tests folder](tests/).

The code follows the [Status Nim Style Guide](https://status-im.github.io/nim-style-guide/).

### Core Developers
[@cheatfate](https://github.com/cheatfate), [Dmitriy Ryajov](https://github.com/dryajov), [Tanguy](https://github.com/Menduist), [Zahary Karadjov](https://github.com/zah)

### Tips and tricks

**enable expensive metrics:**

```bash
nim c -d:libp2p_expensive_metrics some_file.nim
```

**use identify metrics**

```bash
nim c -d:libp2p_agents_metrics -d:KnownLibP2PAgents=nimbus,lighthouse,lodestar,prysm,teku some_file.nim
```

**specify gossipsub specific topics to measure**

```bash
nim c -d:KnownLibP2PTopics=topic1,topic2,topic3 some_file.nim
```

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
