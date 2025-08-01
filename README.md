<h1 align="center">
  <a href="https://libp2p.io"><img width="250" src="./.assets/full-logo.svg?raw=true" alt="nim-libp2p logo" /></a>
</h1>

<h3 align="center">The <a href="https://nim-lang.org/">Nim</a> implementation of the <a href="https://libp2p.io/">libp2p</a> Networking Stack.</h3>

<p align="center">
<a href="https://github.com/vacp2p/nim-libp2p/actions"><img src="https://github.com/vacp2p/nim-libp2p/actions/workflows/ci.yml/badge.svg" /></a>
<a href="https://codecov.io/gh/vacp2p/nim-libp2p"><img src="https://codecov.io/gh/vacp2p/nim-libp2p/branch/master/graph/badge.svg?token=UR5JRQ249W"/></a>

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
- [Development](#development)
  - [Contribute](#contribute)
  - [Contributors](#contributors)
  - [Core Maintainers](#core-maintainers)
- [Modules](#modules)
- [Users](#users)
- [Stability](#stability)
- [License](#license)

## Background
libp2p is a [Peer-to-Peer](https://en.wikipedia.org/wiki/Peer-to-peer) networking stack, with [implementations](https://github.com/libp2p/libp2p#implementations) in multiple languages derived from the same [specifications.](https://github.com/libp2p/specs)

Building large scale peer-to-peer systems has been complex and difficult in the last 15 years and libp2p is a way to fix that. It strives to be a modular stack with secure defaults and useful protocols, while remaining open and extensible.
This is a native Nim implementation, using [chronos](https://github.com/status-im/nim-chronos) for asynchronous execution. It's used in production by a few [projects](#users)

Learn more about libp2p at [**libp2p.io**](https://libp2p.io) and follow libp2p's documentation [**docs.libp2p.io**](https://docs.libp2p.io).

## Install

> The currently supported Nim versions are 2.0 and 2.2.

```
nimble install libp2p
```
You'll find the nim-libp2p documentation [here](https://vacp2p.github.io/nim-libp2p/docs/). See [examples](./examples) for simple usage patterns.

## Getting Started
Try out the chat example. For this you'll need to have [`go-libp2p-daemon`](examples/go-daemon/daemonapi.md) running. Full code can be found [here](https://github.com/status-im/nim-libp2p/blob/master/examples/chat.nim):

```bash
nim c -r --threads:on examples/directchat.nim
```

This will output a peer ID such as `QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu` which you can use in another instance to connect to it.

```bash
./examples/directchat
/connect QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu # change this hash by the hash you were given
```

You can now chat between the instances!

![Chat example](https://imgur.com/caYRu8K.gif)

## Development
Clone the repository and install the dependencies:
```sh
git clone https://github.com/vacp2p/nim-libp2p
cd nim-libp2p
nimble install -dy
```
You can use `nix develop` to start a shell with Nim and Nimble.

nimble 0.20.1 is required for running `testnative`. At time of writing, this is not available in nixpkgs: If using `nix develop`, follow up with `nimble install nimble`, and use that (typically `~/.nimble/bin/nimble`).

### Testing
Run unit tests:
```sh
# run all the unit tests
nimble test
```
**Obs:** Running all tests requires the [`go-libp2p-daemon` to be installed and running](examples/go-daemon/daemonapi.md).

If you only want to run tests that don't require `go-libp2p-daemon`, use:
```
nimble testnative
```

For a list of all available test suites, use:
```
nimble tasks
```

### Contribute

The libp2p implementation in Nim is a work in progress. We welcome contributors to help out! Specifically, you can:
- Go through the modules and **check out existing issues**. This would be especially useful for modules in active development. Some knowledge of IPFS/libp2p may be required, as well as the infrastructure behind it.
- **Perform code reviews**. Feel free to let us know if you found anything that can a) speed up the project development b) ensure better quality and c) reduce possible future bugs.
- **Add tests**. Help nim-libp2p to be more robust by adding more tests to the [tests folder](tests/).
- **Small PRs**. Try to keep PRs atomic and digestible. This makes the review process and pinpointing bugs easier.
- **Code format**. Code should be formatted with [nph](https://github.com/arnetheduck/nph) and follow the [Status Nim Style Guide](https://status-im.github.io/nim-style-guide/).
- **Join the Conversation**. Connect with other contributors in our [community channel](https://discord.com/channels/1204447718093750272/1351621032263417946). Ask questions, share ideas, get support, and stay informed about the latest updates from the maintainers.

### Contributors
<a href="https://github.com/vacp2p/nim-libp2p/graphs/contributors"><img src="https://contrib.rocks/image?repo=vacp2p/nim-libp2p" alt="nim-libp2p contributors"></a>

### Core Maintainers
<table>
  <tbody>
    <tr>
      <td align="center"><a href="https://github.com/richard-ramos"><img src="https://avatars.githubusercontent.com/u/1106587?v=4?s=100" width="100px;" alt="Richard"/><br /><sub><b>Richard</b></sub></a></td>
      <td align="center"><a href="https://github.com/vladopajic"><img src="https://avatars.githubusercontent.com/u/4353513?v=4?s=100" width="100px;" alt="Vlado"/><br /><sub><b>Vlado</b></sub></a></td>
      <td align="center"><a href="https://github.com/gmelodie"><img src="https://avatars.githubusercontent.com/u/8129788?v=4?s=100" width="100px;" alt="Gabe"/><br /><sub><b>Gabe</b></sub></a></td>
    </tr>
  </tbody>
</table>

### Compile time flags

Enable quic transport support
```bash
nim c -d:libp2p_quic_support some_file.nim
```

Enable autotls support
```bash
nim c -d:libp2p_autotls_support some_file.nim
```

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
| [libp2p-quic](libp2p/transports/quictransport.nim)         | Quic Transport                                                                                                   |
| [libp2p-memory](libp2p/transports/memorytransport.nim)     | Memory Transport                                                                                                 |
| **Secure Channels**                                        |                                                                                                                  |
| [libp2p-noise](libp2p/protocols/secure/noise.nim)          | [Noise](https://docs.libp2p.io/concepts/secure-comm/noise/) secure channel                                       |
| [libp2p-plaintext](libp2p/protocols/secure/plaintext.nim)  | Plain Text for development purposes                                                                              |
| **Stream Multiplexers**                                    |                                                                                                                  |
| [libp2p-mplex](libp2p/muxers/mplex/mplex.nim)              | [MPlex](https://github.com/libp2p/specs/tree/master/mplex) multiplexer                                           |
| [libp2p-yamux](libp2p/muxers/yamux/yamux.nim)              | [Yamux](https://docs.libp2p.io/concepts/multiplex/yamux/) multiplexer                                            |
| **Data Types**                                             |                                                                                                                  |
| [peer-id](libp2p/peerid.nim)                               | [Cryptographic identifiers](https://docs.libp2p.io/concepts/fundamentals/peers/#peer-id)                         |
| [peer-store](libp2p/peerstore.nim)                         | [Address book of known peers](https://docs.libp2p.io/concepts/fundamentals/peers/#peer-store)                  |
| [multiaddress](libp2p/multiaddress.nim)                    | [Composable network addresses](https://github.com/multiformats/multiaddr)                                        |
| [signed-envelope](libp2p/signed_envelope.nim)              | [Signed generic data container](https://github.com/libp2p/specs/blob/master/RFC/0002-signed-envelopes.md)        |
| [routing-record](libp2p/routing_record.nim)                | [Signed peer dialing informations](https://github.com/libp2p/specs/blob/master/RFC/0003-routing-records.md)      |
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
- [nwaku](https://github.com/waku-org/nwaku), a decentralized messaging application
- [nim-codex](https://github.com/codex-storage/nim-codex), a decentralized storage application
- (open a pull request if you want to be included here)

## Stability
nim-libp2p has been used in production for over a year in high-stake scenarios, so its core is considered stable.
Some modules are more recent and less stable.

The versioning follows [semver](https://semver.org/), with some additions:
- Some of libp2p procedures are marked as `.public.`, they will remain compatible during each `MAJOR` version
- The rest of the procedures are considered internal, and can change at any `MINOR` version (but remain compatible for each new `PATCH`)

We aim to be compatible at all time with at least 2 Nim `MINOR` versions, currently `2.0 & 2.2`

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
