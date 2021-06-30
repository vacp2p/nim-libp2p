import tables, bearssl
import chronos                              # an efficient library for async
import ../libp2p/[switch,                   # manage transports, a single entry point for dialing and listening
                  builders,                 # helper to build the switch object
                  multistream,              # tag stream with short header to identify it
                  multicodec,               # multicodec utilities
                  crypto/crypto,            # cryptographic functions
                  errors,                   # error handling utilities
                  protocols/identify,       # identify the peer info of a peer
                  stream/connection,        # create and close stream read / write connections
                  transports/transport,     # listen and dial to other peers using p2p protocol
                  multiaddress,             # encode different addressing schemes. For example, /ip4/7.7.7.7/tcp/6543 means it is using IPv4 protocol and TCP
                  peerinfo,                 # manage the information of a peer, such as peer ID and public / private key
                  peerid,                   # Implement how peers interact
                  protocols/protocol,       # define the protocol base type
                  protocols/secure/secure,  # define the protocol of secure connection
                  protocols/secure/secio,   # define the protocol of secure input / output, allows encrypted communication that uses public keys to validate signed messages instead of a certificate authority like in TLS
                  muxers/muxer,             # define an interface for stream multiplexing, allowing peers to offer many protocols over a single connection
                  muxers/mplex/mplex]       # define some contants and message types for stream multiplexing

const TestCodec = "/test/proto/1.0.0" # custom protocol string

type
  TestProto = ref object of LPProtocol # declare a custom protocol

method init(p: TestProto) {.gcsafe.} =
  # handle incoming connections in closure
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    echo "Got from remote - ", cast[string](await conn.readLp(1024))
    await conn.writeLp("Roger p2p!")
    await conn.close()

  p.codec = TestCodec # init proto with the correct string id
  p.handler = handle # set proto handler

proc createSwitch(ma: MultiAddress, rng: ref BrHmacDrbgContext): (Switch, PeerInfo) =
  ## Helper to create a switch
  var switch = SwitchBuilder
    .new()
    .withRng(rng)       # Give the application RNG
    .withAddress(ma)    # Our local address(es)
    .withTcpTransport() # Use TCP as transport
    .withMplex()        # Use Mplex as muxer
    .withNoise()        # Use Noise as secure manager
    .build()

  result = (switch, switch.peerInfo)

proc main() {.async, gcsafe.} =
  let
    rng = newRng() # Singe random number source for the whole application
    ma1: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
    ma2: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

  # setup the custom proto
  let testProto = new TestProto
  testProto.init() # run it's init method to perform any required initialization

  # setup the two nodes
  var peerInfo1, peerInfo2: PeerInfo
  var switch1, switch2: Switch
  (switch1, peerInfo1) = createSwitch(ma1, rng) # create node 1
  switch1.mount(testProto) # mount the proto
  var switch1Fut = await switch1.start() # start the node

  (switch2, peerInfo2) = createSwitch(ma2, rng) # create node 2
  var switch2Fut = await switch2.start() # start second node

  # dial the first node
  let conn = await switch2.dial(switch1.peerInfo, TestCodec)

  await conn.writeLp("Hello p2p!") # writeLp send a length prefixed buffer over the wire
  # readLp reads length prefixed bytes and returns a buffer without the prefix
  echo "Remote responded with - ", cast[string](await conn.readLp(1024))

  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports
  await allFutures(switch1Fut & switch2Fut) # wait for all transports to shutdown

waitFor(main())
