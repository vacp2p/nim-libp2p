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
</p>

## Background

libp2p is a [Peer-to-Peer](https://en.wikipedia.org/wiki/Peer-to-peer) networking stack, with [implementations](https://github.com/libp2p/libp2p#implementations) in multiple languages derived from the same [specifications.](https://github.com/libp2p/specs)

Building large scale peer-to-peer systems has been complex and difficult in the last 15 years and libp2p is a way to fix that. It strives to be a modular stack with secure defaults and useful protocols, while remaining open and extensible.
This is a native Nim implementation, using [chronos](https://github.com/status-im/nim-chronos) for asynchronous execution. It's used in production by a few [projects](#users).

Learn more about libp2p at [**libp2p.io**](https://libp2p.io) and follow libp2p's documentation [**docs.libp2p.io**](https://docs.libp2p.io).

## Contribute

nim-libp2p is a great place to contribute. Your contribution will help drive thousands of decentralized nodes across networks worldwide.

The best part is that nim-libp2p has **good first issues** that are especially suited for newcomers. Your contributions will be guided by core maintainers, just like an **internship experience** but decentralized.

Jump into the [contributing](docs/contributing.md) page to get started, `nim-libp2p` is expecting your contribution!

## Install

The currently supported Nim versions are v2.0.16 and v2.2.6.

```
nimble install libp2p
```

You'll find the nim-libp2p documentation [here](https://vacp2p.github.io/nim-libp2p/docs/). See [examples](./examples) for simple usage patterns.

## Development

See the [development guide](docs/development.md) to get started with the project and testing.
For more details, refer to the [documentation](docs/README.md).

## Contributors

Thanks to everyone who has contributed to nim-libp2p. Your support and efforts are greatly appreciated.

<a href="https://github.com/vacp2p/nim-libp2p/graphs/contributors"><img src="https://contrib.rocks/image?repo=vacp2p/nim-libp2p" alt="nim-libp2p contributors"></a>

## Join the Conversation

Connect with other contributors in our [community channel](https://discord.com/channels/1204447718093750272/1351621032263417946). Ask questions, share ideas, get support, and stay informed about the latest updates from the maintainers.

## Users

nim-libp2p is used by:

- [Nimbus](https://github.com/status-im/nimbus-eth2), an Ethereum client
- [logos-delivery](https://github.com/logos-messaging/logos-delivery), a decentralized messaging protocols
- [logos-storage](https://github.com/logos-storage/logos-storage-nim), a decentralized storage protocols
- (open a pull request if you want to be included here)

## Stability

nim-libp2p has been used in production for many years in high-stake scenarios, so its core is considered stable.
Some modules are more recent and less stable.

The versioning follows [semver](https://semver.org/), with some additions:

- Some of libp2p procedures are marked as `.public.`, they will remain compatible during each `MAJOR` version
- The rest of the procedures are considered internal, and can change at any `MINOR` version (but remain compatible for each new `PATCH`)

## License

Licensed and distributed under either of

- MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

- Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.

## Modules

List of packages modules implemented in nim-libp2p:

| Name                                                      | Description                                                                                                |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **Libp2p**                                                |                                                                                                            |
| [libp2p](libp2p/switch.nim)                               | The core of the project                                                                                    |
| [connmanager](libp2p/connmanager.nim)                     | Connection manager                                                                                         |
| [identify / push identify](libp2p/protocols/identify.nim) | [Identify](https://docs.libp2p.io/concepts/fundamentals/protocols/#identify) protocol                      |
| [ping](libp2p/protocols/ping.nim)                         | [Ping](https://docs.libp2p.io/concepts/fundamentals/protocols/#ping) protocol                              |
| **Transports**                                            |                                                                                                            |
| [libp2p-tcp](libp2p/transports/tcptransport.nim)          | TCP transport                                                                                              |
| [libp2p-ws](libp2p/transports/wstransport.nim)            | WebSocket & WebSocket Secure transport                                                                     |
| [libp2p-tor](libp2p/transports/tortransport.nim)          | Tor Transport                                                                                              |
| [libp2p-quic](libp2p/transports/quictransport.nim)        | Quic Transport                                                                                             |
| [libp2p-memory](libp2p/transports/memorytransport.nim)    | Memory Transport                                                                                           |
| **Secure Channels**                                       |                                                                                                            |
| [libp2p-noise](libp2p/protocols/secure/noise.nim)         | [Noise](https://docs.libp2p.io/concepts/secure-comm/noise/) secure channel                                 |
| [libp2p-plaintext](libp2p/protocols/secure/plaintext.nim) | Plain Text for development purposes                                                                        |
| **Stream Multiplexers**                                   |                                                                                                            |
| [libp2p-mplex](libp2p/muxers/mplex/mplex.nim)             | [MPlex](https://github.com/libp2p/specs/tree/master/mplex) multiplexer                                     |
| [libp2p-yamux](libp2p/muxers/yamux/yamux.nim)             | [Yamux](https://docs.libp2p.io/concepts/multiplex/yamux/) multiplexer                                      |
| **Data Types**                                            |                                                                                                            |
| [peer-id](libp2p/peerid.nim)                              | [Cryptographic identifiers](https://docs.libp2p.io/concepts/fundamentals/peers/#peer-id)                   |
| [peer-store](libp2p/peerstore.nim)                        | [Address book of known peers](https://docs.libp2p.io/concepts/fundamentals/peers/#peer-store)              |
| [multiaddress](libp2p/multiaddress.nim)                   | [Composable network addresses](https://github.com/multiformats/multiaddr)                                  |
| [signed-envelope](libp2p/signed_envelope.nim)             | [Signed generic data container](https://github.com/libp2p/specs/blob/master/RFC/0002-signed-envelopes.md)  |
| [routing-record](libp2p/routing_record.nim)               | [Signed peer dialing information](https://github.com/libp2p/specs/blob/master/RFC/0003-routing-records.md) |
| [discovery manager](libp2p/discovery/discoverymngr.nim)   | Discovery Manager                                                                                          |
| **Utilities**                                             |                                                                                                            |
| [libp2p-crypto](libp2p/crypto)                            | Cryptographic backend                                                                                      |
| [libp2p-crypto-secp256k1](libp2p/crypto/secp.nim)         |                                                                                                            |
| **Pubsub**                                                |                                                                                                            |
| [libp2p-pubsub](libp2p/protocols/pubsub/pubsub.nim)       | Pub-Sub generic interface                                                                                  |
| [libp2p-floodsub](libp2p/protocols/pubsub/floodsub.nim)   | FloodSub implementation                                                                                    |
| [libp2p-gossipsub](libp2p/protocols/pubsub/gossipsub.nim) | [GossipSub](https://docs.libp2p.io/concepts/publish-subscribe/) implementation                             |
