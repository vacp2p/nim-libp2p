import tables
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
       ../libp2p/protocols/secure/secio

type
  TestProto = ref object of LPProtocol

method init(p: TestProto) {.gcsafe.} =
  proc handle(stream: Connection, proto: string) {.async, gcsafe.} = 
    await stream.writeLp("Hello from handler")
    await stream.close()

  p.codec = "/test/proto/1.0.0"
  p.handler = handle

proc newTestProto(): TestProto = 
  new result
  result.init()

proc main() {.async.} =
  let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/30333")

  let seckey = PrivateKey.random(RSA)
  var peerInfo: PeerInfo
  peerInfo.peerId = PeerID.init(seckey)
  peerInfo.addrs.add(Multiaddress.init("/ip4/127.0.0.1/tcp/55055"))

  proc createMplex(conn: Connection): Muxer =
    result = newMplex(conn)

  let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  let transports = @[Transport(newTransport(TcpTransport))]
  let muxers = [(MplexCodec, mplexProvider)].toTable()
  let identify = newIdentify(peerInfo)
  let switch = newSwitch(peerInfo, transports, identify, muxers, @[Secure(newSecIo(seckey.getKey()))])

  await switch.start()

  var remotePeer: PeerInfo
  remotePeer.peerId = PeerID.init("QmUA1Ghihi5u3gDwEDxhbu49jU42QPbvHttZFwB6b4K5oC")
  remotePeer.addrs.add(ma)

  switch.mount(newTestProto())
  echo "PeerID: " & peerInfo.peerId.pretty
  let conn = await switch.dial(remotePeer, "/test/proto/1.0.0")
  await conn.writeLp("Hello from dialer!")
  let msg = cast[string](await conn.readLp())
  echo msg
  await conn.close()

waitFor(main())