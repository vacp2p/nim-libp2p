<h1 align="center">
  <a href="https://libp2p.io"><img width="250" src="./.assets/full-logo.svg?raw=true" alt="nim-libp2p logo" /></a>
</h1>

<h3 align="center">The <a href="https://nim-lang.org/">Nim</a> implementation of the <a href="https://libp2p.io/">libp2p</a> Networking Stack.</h3>

<p align="center">
<a href="https://github.com/status-im/nim-libp2p/actions"><img src="https://github.com/status-im/nim-libp2p/actions/workflows/ci.yml/badge.svg" /></a>
<a href="https://codecov.io/gh/status-im/nim-libp2p"><img src="https://codecov.io/gh/status-im/nim-libp2p/branch/master/graph/badge.svg?token=UR5JRQ249W"/></a>

</p>

<p align="center">
<a href="https://opensource.org/licenses/Apache-2.0"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" /></a>
<a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" /></a>
<img src="https://img.shields.io/badge/nim-%3E%3D1.2.0-orange.svg?style=flat-square" />
</p>

# Table of Contents
- [Background](#background)
- [Install](#install)
- [Getting Started](#getting-started)
- [Modules](#modules)
- [Users](#users)
- [Stability](#stability)
- [Development](#development)
  - [Contribute](#contribute)
  - [Contributors](#contributors)
  - [Core Maintainers](#core-maintainers)
- [License](#license)

## Background
libp2p is a [Peer-to-Peer](https://en.wikipedia.org/wiki/Peer-to-peer) networking stack, with [implementations](https://github.com/libp2p/libp2p#implementations) in multiple languages derived from the same [specifications.](https://github.com/libp2p/specs)

Building large scale peer-to-peer systems has been complex and difficult in the last 15 years and libp2p is a way to fix that. It's striving to be a modular stack, with sane and secure defaults, useful protocols, while remain open and extensible.
This implementation in native Nim, relying on [chronos](https://github.com/status-im/nim-chronos) for async. It's used in production by a few [projects](#users)

Learn more about libp2p at [**libp2p.io**](https://libp2p.io) and follow libp2p's documentation [**docs.libp2p.io**](https://docs.libp2p.io).

## Install
**Prerequisite**
- [Nim](https://nim-lang.org/install.html)
```
nimble install libp2p
```

## Getting Started
You'll find the nim-libp2p documentation [here](https://status-im.github.io/nim-libp2p/docs/).

**Go Daemon:**
Please find the installation and usage intructions in [daemonapi.md](examples/go-daemon/daemonapi.md).

## Modules

List of packages modules implemented in nim-libp2p:

| Name                                                       | Description                                                                                                      |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Libp2p**                                                 |                                                                                                                  |
| [libp2p](libp2p/switch.nim)                                | The core of the project                                                                                          |
| [connmanager](libp2p/connmanager.nim)                      | Connection manager                                                                                               |
| [identify / push identify](libp2p/protocols/identify.nim)  | [Identify](https://docs.libp2p.io/concepts/fundamentals/protocols/#identify) protocol                            |
| [ping](libp2p/protocols/ping.nim)                          | [Ping](https://docs.libp2p.io/concepts/fundamentals/protocols/#ping) protocol                                    |
| [libp2p-daemon-client](libp2p/daemon/daemonapi.nim)        | [go-daemon](https://github.com/libp2p/go-libp2p-daemon) nim wrapper                                              |
| [interop-libp2p](tests/testinterop.nim)                    | Interop tests                                                                                                    |
| **Transports**                                             |                                                                                                                  |
| [libp2p-tcp](libp2p/transports/tcptransport.nim)           | TCP transport                                                                                                    |
| [libp2p-ws](libp2p/transports/wstransport.nim)             | WebSocket & WebSocket Secure transport                                                                           |
| [libp2p-tor](libp2p/transports/tortransport.nim)           | Tor Transport                                                                                                    |
| **Secure Channels**                                        |                                                                                                                  |
| [libp2p-secio](libp2p/protocols/secure/secio.nim)          | Secio secure channel                                                                                             |
| [libp2p-noise](libp2p/protocols/secure/noise.nim)          | [Noise](https://docs.libp2p.io/concepts/secure-comm/noise/) secure channel                                       |
| [libp2p-plaintext](libp2p/protocols/secure/plaintext.nim)  | Plain Text for development purposes                                                                              |
| **Stream Multiplexers**                                    |                                                                                                                  |
| [libp2p-mplex](libp2p/muxers/mplex/mplex.nim)              | [MPlex](https://github.com/libp2p/specs/tree/master/mplex) multiplexer                                           |
| [libp2p-yamux](libp2p/muxers/yamux/yamux.nim)              | [Yamux](https://docs.libp2p.io/concepts/multiplex/yamux/) multiplexer                                            |
| **Data Types**                                             |                                                                                                                  |
| [peer-id](libp2p/peerid.nim)                               | [Cryptographic identifiers](https://docs.libp2p.io/concepts/fundamentals/peers/#peer-id)                         |
| [peer-store](libp2p/peerstore.nim)                         | ["Address book" of known peers](https://docs.libp2p.io/concepts/fundamentals/peers/#peer-store)                  |
| [multiaddress](libp2p/multiaddress.nim)                    | [Composable network addresses](https://github.com/multiformats/multiaddr)                                        |
| [signed envelope](libp2p/signed_envelope.nim)              | [Signed generic data container](https://github.com/libp2p/specs/blob/master/RFC/0002-signed-envelopes.md)        |
| [routing record](libp2p/routing_record.nim)                | [Signed peer dialing informations](https://github.com/libp2p/specs/blob/master/RFC/0003-routing-records.md)      |
| [discovery manager](libp2p/discovery/discoverymngr.nim)    | Discovery Manager                                                                                                |
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

## Stability
nim-libp2p has been used in production for over a year in high-stake scenarios, so its core is considered stable.
Some modules are more recent and less stable.

The versioning follows [semver](https://semver.org/), with some additions:
- Some of libp2p procedures are marked as `.public.`, they will remain compatible during each `MAJOR` version
- The rest of the procedures are considered internal, and can change at any `MINOR` version (but remain compatible for each new `PATCH`)

We aim to be compatible at all time with at least 2 Nim `MINOR` versions, currently `1.2 & 1.6`

## Development
Clone and Install dependencies:
```sh
git clone https://github.com/status-im/nim-libp2p
cd nim-libp2p
# to use dependencies computed by nimble
nimble install -dy
# OR to install the dependencies versions used in CI
nimble install_pinned
```

Run unit tests:
```sh
# run all the unit tests
nimble test
```
This requires the go daemon to be available. To only run native tests, use `nimble testnative`.
Or use `nimble tasks` to show all available tasks.

### Contribute

The libp2p implementation in Nim is a work in progress. We welcome contributors to help out! Specifically, you can:
- Go through the modules and **check out existing issues**. This would be especially useful for modules in active development. Some knowledge of IPFS/libp2p may be required, as well as the infrastructure behind it.
- **Perform code reviews**. Feel free to let us know if you found anything that can a) speed up the project development b) ensure better quality and c) reduce possible future bugs.
- **Add tests**. Help nim-libp2p to be more robust by adding more tests to the [tests folder](tests/).

The code follows the [Status Nim Style Guide](https://status-im.github.io/nim-style-guide/).

### Contributors
<a href="https://github.com/status-im/nim-libp2p/graphs/contributors"><img src="https://contrib.rocks/image?repo=status-im/nim-libp2p" alt="nim-libp2p contributors"></a>

### Core Maintainers
<table>
  <tbody>
    <tr>
      <td align="center"><a href="https://github.com/Menduist"><img src="https://avatars.githubusercontent.com/u/13471753?v=4?s=100" width="100px;" alt="Tanguy"/><br /><sub><b>Tanguy (Menduist)</b></sub></a></td>
      <td align="center"><a href="https://github.com/lchenut"><img src="https://avatars.githubusercontent.com/u/11214565?v=4?s=100" width="100px;" alt="Ludovic"/><br /><sub><b>Ludovic</b></sub></a></td>
      <td align="center"><a href="https://github.com/diegomrsantos"><img src="https://avatars.githubusercontent.com/u/7316595?v=4?s=100" width="100px;" alt="Diego"/><br /><sub><b>Diego</b></sub></a></td>
    </tr>
  </tbody>
</table>

### Compile time flags

Enable expensive metrics (ie, metrics with per-peer cardinality):
```bash
nim c -d:libp2p_expensive_metrics some_file.nim
```

Set list of known libp2p agents for metrics:
```bash
nim c -d:libp2p_agents_metrics -d:KnownLibP2PAgents=nimbus,lighthouse,lodestar,prysm,teku some_file.nim
```

Specify gossipsub specific topics to measure in the metrics:
```bash
nim c -d:KnownLibP2PTopics=topic1,topic2,topic3 some_file.nim
```

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
