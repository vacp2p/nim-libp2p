import tables, options, sequtils
import chronos, chronicles
import ../libp2p/switch, 
       ../libp2p/multistream,
       ../libp2p/protocols/identify, 
       ../libp2p/connection,
       ../libp2p/transports/[transport, tcptransport], 
       ../libp2p/multiaddress, 
       ../libp2p/peerinfo,
       ../libp2p/crypto/crypto, 
       ../libp2p/peer,
       ../libp2p/protocols/protocol, 
       ../libp2p/muxers/muxer,
       ../libp2p/muxers/mplex/mplex, 
       ../libp2p/muxers/mplex/types,
       ../libp2p/protocols/secure/secure,
       ../libp2p/protocols/secure/secio,
       ../libp2p/protocols/pubsub/pubsub,
       ../libp2p/protocols/pubsub/floodsub

type
  TestProto = ref object of LPProtocol
    switch*: Switch

method init(p: TestProto) {.gcsafe.} =
  proc handle(stream: Connection, proto: string) {.async, gcsafe.} = discard

  p.codec = "/test/proto/1.0.0"
  p.handler = handle

proc newTestProto(switch: Switch): TestProto = 
  new result
  result.switch = switch
  result.init()

proc main() {.async.} =
  let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/30333")

  let seckey = PrivateKey.random(RSA)
  var peerInfo: PeerInfo
  peerInfo.peerId = some(PeerID.init(seckey))
  peerInfo.addrs.add(Multiaddress.init("/ip4/127.0.0.1/tcp/55055"))

  proc createMplex(conn: Connection): Muxer =
    result = newMplex(conn)

  let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  let transports = @[Transport(newTransport(TcpTransport))]
  let muxers = [(MplexCodec, mplexProvider)].toTable()
  let identify = newIdentify(peerInfo)
  # let secureManagers = @[Secure(newSecIo(seckey.getKey()))]
  let pubSub = some(PubSub(newFloodSub(peerInfo)))
  let switch = newSwitch(peerInfo, transports, identify, muxers, pubSub = pubSub)

  var libp2pFuts = await switch.start()
  echo "Right after start"
  for item in libp2pFuts:
    echo item.finished

  var remotePeer: PeerInfo
  remotePeer.peerId = some(PeerID.init("QmUA1Ghihi5u3gDwEDxhbu49jU42QPbvHttZFwB6b4K5oC"))
  remotePeer.addrs.add(ma)

  switch.mount(newTestProto(switch))
  echo "PeerID: " & peerInfo.peerId.get().pretty
  # let conn = await switch.dial(remotePeer, "/test/proto/1.0.0")
  await switch.subscribeToPeer(remotePeer)

  proc handler(topic: string, data: seq[byte]): Future[void] {.closure, gcsafe.} =
    debug "IN HANDLER"

  await switch.subscribe("mytesttopic", handler)
  # let msg = cast[seq[byte]]("hello from nim")
  # await switch.publish("mytesttopic", msg)
  # debug "published message from test"
  # TODO: for some reason the connection closes unless I do a forever loop
  await allFutures(libp2pFuts)

waitFor(main())