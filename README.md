# nim-libp2p

[![Build Status](https://travis-ci.org/status-im/nim-libp2p.svg?branch=master)](https://travis-ci.org/status-im/nim-libp2p)
[![Build status](https://ci.appveyor.com/api/projects/status/pqgif5bcie6cp3wi/branch/master?svg=true)](https://ci.appveyor.com/project/nimbus/nim-libp2p/branch/master)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

## Introduction

### Running against the Go daemon

An implementation of [libp2p](https://libp2p.io/) in Nim, as a wrapper of the [Libp2p Go daemon](https://github.com/libp2p/go-libp2p).

Note that you need Go 1.12+ for the below instructions to work!

Install dependencies and run tests with:

```bash
git clone https://github.com/status-im/nim-libp2p && cd nim-libp2p
nimble install
nimble test
git submodule update --init --recursive
go version
git clone https://github.com/libp2p/go-libp2p-daemon
cd go-libp2p-daemon
git checkout v0.0.1
go install ./...
cd ..
```

Try out the chat example:

```bash
nim c -r --threads:on examples\chat.nim
```

This will output a peer ID such as `QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu` which you can use in another instance to connect to it.

```bash
./example/chat
/connect QmbmHfVvouKammmQDJck4hz33WvVktNEe7pasxz2HgseRu
```

You can now chat between the instances!

![Chat example](https://imgur.com/caYRu8K.gif)

## API

Coming soon...

## Experimental native implementation

The native Nim libp2p implementation has finally arrived. Currently, it's support is experimental and shouldn't be relied on for production use. It is however under active development and we hope to achieve a reasonable level of stability in the upcoming months, as we will be integrating it across our own set of products, such as the Nim Beacon Chain.

### What to expect?

The current implementation implements a bare minimum set of components in order to provide a functional and interoperable libp2p implementation. These are:

- A TCP transport
- multistream-select
- Secio
- Mplex
- Identify
- FloodSub (with gossipsub being added in the near future)

This stack reflects the minimal requirements for the upcoming Eth2 implementation.

### How to try it out?

To run it, add nim-libp2p to your project's nimble file and spawn a node as follows:

```nim
import tables, options
import chronos, chronicles
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
    let msg = cast[string](await conn.readLp())
    echo "Got from remote - ", cast[string](msg)
    await conn.writeLp("Hello!")
    await conn.close()

  p.codec = TestCodec # init proto with the correct string id
  p.handler = handle # set proto handler

proc createSwitch(ma: MultiAddress): (Switch, PeerInfo) =
  ## Helper to create a swith

  let seckey = PrivateKey.random(RSA) # use a random key for peer id
  var peerInfo: PeerInfo
  peerInfo.peerId = some(PeerID.init(seckey)) # create a peer id and assign
  peerInfo.addrs.add(ma) # set this peer's multiaddresses (can be any number)

  let identify = newIdentify(peerInfo) # create the identify proto

  proc createMplex(conn: Connection): Muxer =
    # helper proc to create multiplexers, 
    # use this to perform any custom setup up,
    # su as adjusting timeout or anything else 
    # that the muxer requires
    result = newMplex(conn)

  let mplexProvider = newMuxerProvider(createMplex, MplexCodec) # create multiplexer
  let transports = @[Transport(newTransport(TcpTransport))] # add all transports (tcp only for now, but can be anything in the future)
  let muxers = [(MplexCodec, mplexProvider)].toTable() # add all muxers
  let secureManagers = [(SecioCodec, Secure(newSecio(seckey)))].toTable() # setup the secio and any other secure provider

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

  await conn.writeLp("Hello!") # writeLp send a lenght prefixed buffer over the wire
  let msg = cast[string](await conn.readLp()) # readLp reads a lenght prefixed bytes and returns a buffer without the prefix
  echo "Remote responded with - ", cast[string](msg)

  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports
  await allFutures(switch1Fut & switch2Fut) # wait for all transports to shutdown

waitFor(main())
```

For a more complete example, checkout the [directchat.nim](examples/directchat.nim) example in the `examples` directory.

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. This file may not be copied, modified, or distributed except according to those terms.
