# Getting Started
Welcome to nim-libp2p! This guide will walk you through a peer to peer chat example. <br>
The full code can be found in [directchat.nim](examples/directchat.nim) under the examples folder.


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
                  peerid,
                  protocols/protocol,
                  muxers/muxer,
                  muxers/mplex/mplex,
                  protocols/secure/secio,
                  protocols/secure/secure]

const TestCodec = "/test/proto/1.0.0" # custom protocol string

type
  TestProto = ref object of LPProtocol # declare a custom protocol

method init(p: TestProto) {.gcsafe.} =
  # handle incoming connections in closure
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    echo "Got from remote - ", cast[string](await conn.readLp(1024))
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
  let secureManagers = {SecioCodec: Secure(Secio.new(seckey))}.toTable() # setup the secio and any other secure provider

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
  echo "Remote responded with - ", cast[string](await conn.readLp(1024))

  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports
  await allFutures(switch1Fut & switch2Fut) # wait for all transports to shutdown

waitFor(main())
```
