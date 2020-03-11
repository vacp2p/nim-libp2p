# nim-libp2p

[![Build Status](https://travis-ci.org/status-im/nim-libp2p.svg?branch=master)](https://travis-ci.org/status-im/nim-libp2p)
[![Build status](https://ci.appveyor.com/api/projects/status/pqgif5bcie6cp3wi/branch/master?svg=true)](https://ci.appveyor.com/project/nimbus/nim-libp2p/branch/master)
[![Build Status: Azure](https://img.shields.io/azure-devops/build/nimbus-dev/dc5eed24-3f6c-4c06-8466-3d060abd6c8b/5/master?label=Azure%20%28Linux%2064-bit%2C%20Windows%2032-bit%2F64-bit%2C%20MacOS%2064-bit%29)](https://dev.azure.com/nimbus-dev/nim-libp2p/_build?definitionId=5&branchName=master)

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

## Introduction

An implementation of [libp2p](https://libp2p.io/) in Nim. Also provides a Nim wrapper of the [Libp2p Go daemon](https://github.com/libp2p/go-libp2p).

## Project Status
The current native Nim libp2p implementation support is experimental and shouldn't be relied on for production use. It is however under active development and we hope to achieve a reasonable level of stability in the upcoming months, as we will be integrating it across our own set of products, such as the Nim Beacon Chain. <br>

Check our [examples folder](/examples) to get started! 

# Table of Contents
- [Background](#background)
- [Install](#install)
  - [Prerequisite](#prerequisite)
- [Usage](#usage)
  - [Configuration](#configuration)
  - [API](#api)
  - [Getting Started](#getting-started)
  - [Tutorials and Examples](#tutorials-and-examples)
  - [Using the Go Daemon](#using-the-go-daemon)
- [Development](#development)
  - [Tests](#tests)
  - [Packages](#packages)
- [Contribute](#contribute)
  - [Core Developers](#core-developers) 
- [License](#license)

## Background   

## Install
```
nimble install libp2p
```
### Prerequisite 
- [Nim](https://nim-lang.org/install.html)
- [Go 1.12+](https://golang.org/dl/) 

## Usage

### Getting Started

Examples can be found in the [examples folder](/examples). Below is a quick overview of the [directchat.nim](examples/directchat.nim) example.


### Direct Chat Example
To run nim-libp2p, add it to your project's nimble file and spawn a node as follows:

```nim
import tables
import chronos
import ../libp2p/[switch,
                  multistream,
                  protocols/identify,
                  connection,
                  transports/transport,
                  transports/tcptransport,
                  multiaddress,
                  peerinfo,
                  crypto/crypto,
                  peer,
                  protocols/protocol,
                  muxers/muxer,
                  muxers/mplex/mplex,
                  muxers/mplex/types,
                  protocols/secure/secio,
                  protocols/secure/secure]

const TestCodec = "/test/proto/1.0.0" # custom protocol string

type
  TestProto = ref object of LPProtocol # declare a custom protocol

method init(p: TestProto) {.gcsafe.} =
  # handle incoming connections in closure
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    echo "Got from remote - ", cast[string](await conn.readLp())
    await conn.writeLp("Hello!")
    await conn.close()

  p.codec = TestCodec # init proto with the correct string id
  p.handler = handle # set proto handler

proc createSwitch(ma: MultiAddress): (Switch, PeerInfo) =
  ## Helper to create a swith

  let seckey = PrivateKey.random(RSA) # use a random key for peer id
  var peerInfo = PeerInfo.init(seckey) # create a peer id and assign
  peerInfo.addrs.add(ma) # set this peer's multiaddresses (can be any number)

  let identify = newIdentify(peerInfo) # create the identify proto

  proc createMplex(conn: Connection): Muxer =
    # helper proc to create multiplexers,
    # use this to perform any custom setup up,
    # such as adjusting timeout or anything else
    # that the muxer requires
    result = newMplex(conn)

  let mplexProvider = newMuxerProvider(createMplex, MplexCodec) # create multiplexer
  let transports = @[Transport(newTransport(TcpTransport))] # add all transports (tcp only for now, but can be anything in the future)
  let muxers = {MplexCodec: mplexProvider}.toTable() # add all muxers
  let secureManagers = {SecioCodec: Secure(newSecio(seckey))}.toTable() # setup the secio and any other secure provider

  # create the switch
  let switch = newSwitch(peerInfo,
                         transports,
                         identify,
                         muxers,
                         secureManagers)
  result = (switch, peerInfo)

proc main() {.async, gcsafe.} =
  let ma1: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
  let ma2: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

  var peerInfo1, peerInfo2: PeerInfo
  var switch1, switch2: Switch
  (switch1, peerInfo1) = createSwitch(ma1) # create node 1

  # setup the custom proto
  let testProto = new TestProto
  testProto.init() # run it's init method to perform any required initialization
  switch1.mount(testProto) # mount the proto
  var switch1Fut = await switch1.start() # start the node

  (switch2, peerInfo2) = createSwitch(ma2) # create node 2
  var switch2Fut = await switch2.start() # start second node
  let conn = await switch2.dial(switch1.peerInfo, TestCodec) # dial the first node

  await conn.writeLp("Hello!") # writeLp send a length prefixed buffer over the wire
  # readLp reads length prefixed bytes and returns a buffer without the prefix
  echo "Remote responded with - ", cast[string](await conn.readLp())

  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports
  await allFutures(switch1Fut & switch2Fut) # wait for all transports to shutdown

waitFor(main())
```

### Using the Go Daemon
Please find the installation and usage intructions on the [Wiki page](https://github.com/status-im/nim-libp2p/wiki/Go-Libp2p-Daemon-Interface#introduction). 

## Development
**Clone and Install dependencies:**

```sh
> git clone https://github.com/status-im/nim-libp2p
> cd nim-libp2p
> nimble install
```

### Tests 
#### Run unit tests
```sh
# run all the unit tests
> nimble test
```

### Packages 

List of packages currently in existence for nim-libp2p:

#### Libp2p
- [libp2p](https://github.com/status-im/nim-libp2p)
- [libp2p-daemon-client](https://github.com/status-im/nim-libp2p/blob/5701d937c8d36a1f629073130d26246ecc02caf7/libp2p/daemon/daemonapi.nim)
- [interop-libp2p](https://github.com/status-im/nim-libp2p/blob/5701d937c8d36a1f629073130d26246ecc02caf7/tests/testinterop.nim#L191)

#### Transports
- [libp2p-tcp](https://github.com/status-im/nim-libp2p/blob/293a219dbe078636ce5891c3423ab10ffe3112f9/libp2p/transports/tcptransport.nim)

#### Secure Channels
- [libp2p-secio](https://github.com/status-im/nim-libp2p/blob/df29ac760e51b5a1815f313a8cdc1bdf428dbafc/libp2p/protocols/secure/secio.nim)

#### Stream Multiplexers
- [libp2p-mplex](https://github.com/status-im/nim-libp2p/blob/1a987a9c5b5bc4fd35e71576aa54ba7e5a5979e9/libp2p/muxers/mplex/mplex.nim)

#### Utilities
- [libp2p-crypto](https://github.com/status-im/nim-libp2p/tree/master/libp2p/crypto)
- [libp2p-crypto-secp256k1](https://github.com/status-im/nim-libp2p/blob/107e71203d136acbabe9d8af45bcad58967eeec0/libp2p/crypto/secp.nim)

#### Data Types
- [peer-id](https://github.com/status-im/nim-libp2p/blob/e0aae6d8ac1b4389044c5a6332add796bdf1d3a7/libp2p/peer.nim)
- [peer-info](https://github.com/status-im/nim-libp2p/blob/8e46460cf61e6ea6e370eff98a9ad85774f87d79/libp2p/peerinfo.nim)

#### Pubsub
- [libp2p-pubsub](https://github.com/status-im/nim-libp2p/blob/6a7f9f058c04ecdfd26e5dbfd8df88221b8511e7/libp2p/protocols/pubsub/pubsub.nim)
- [libp2p-floodsub](https://github.com/status-im/nim-libp2p/blob/d5f92663bc5faa6d163d28624d66d740af4942c7/libp2p/protocols/pubsub/floodsub.nim)
- [libp2p-gossipsub](https://github.com/status-im/nim-libp2p/blob/381630f1854818be634a98e92a65dc317bf780a0/libp2p/protocols/pubsub/gossipsub.nim)


Packages that is under active development: 
```
libp2p-daemon
libp2p-webrtc-direct
libp2p-webrtc-star
libp2p-websockets
libp2p-spdy
libp2p-bootstrap
libp2p-kad-dht
libp2p-mdns
libp2p-webrtc-star libp2p-delegated-content-routing libp2p-delegated-peer-routing
libp2p-nat-mgnr
libp2p-utils
```

** Note that the current stack reflects the minimal requirements for the upcoming Eth2 implementation. <br>

## Contribute
The libp2p implementation in Nim is a work in progress. We welcome contributors to help out! In specific, you can:
- Go through the modules and **check out existing issues**. This would be especially useful for modules in active development. Some knowledge of IPFS/libp2p may be required, as well as the infrastructure behind it. 
- **Perform code reviews**. Feel free to let us know if you found anything that can a) speed up the project development b) ensure better quality and c) reduce possible future bugs. 
- **Add tests**. Help nim-libp2p to be more robust by adding more tests to the [tests folder](https://github.com/status-im/nim-libp2p/tree/master/tests).

### Core Developers 
[Eugene Kabanov](https://github.com/cheatfate), [Dmitriy Ryajov](https://github.com/dryajov), [Giovanni Petrantoni](https://github.com/sinkingsugar), [Zahary](https://github.com/zah)

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. This file may not be copied, modified, or distributed except according to those terms.
