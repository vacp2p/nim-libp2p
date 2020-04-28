import unittest, chronos, tables
import libp2p/[switch,
               multistream,
               protocols/identify,
               connection,
               transports/transport,
               transports/tcptransport,
               multiaddress,
               peerinfo,
               crypto/crypto,
               peer,
               peerinfo,
               protocols/protocol,
               muxers/muxer,
               muxers/mplex/mplex,
               muxers/mplex/types,
               protocols/secure/secio,
               protocols/secure/secure]

const TestCodec = "/test/proto/1.0.0"
type TestProto = ref object of LPProtocol

proc createSwitch(ma: MultiAddress): (Switch, PeerInfo) =
  var peerInfo: PeerInfo = PeerInfo.init(PrivateKey.random(RSA))
  peerInfo.addrs.add(ma)
  let identify = newIdentify(peerInfo)

  proc createMplex(conn: Connection): Muxer =
    result = newMplex(conn)

  let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  let transports = @[Transport(newTransport(TcpTransport))]
  let muxers = [(MplexCodec, mplexProvider)].toTable()
  let secureManagers = [(SecioCodec, Secure(newSecio(peerInfo.privateKey)))].toTable()
  let switch = newSwitch(peerInfo,
                         transports,
                         identify,
                         muxers,
                         secureManagers)
  result = (switch, peerInfo)

proc testSwitch(): Future[bool] {.async, gcsafe.} =

  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    await conn.writeLp("Hello")
    await conn.close()

  let ma1: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
  let ma2: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

  var peerInfo1, peerInfo2: PeerInfo
  var switch1, switch2: Switch
  var awaiters: seq[Future[void]]

  (switch1, peerInfo1) = createSwitch(ma1)

  let testProto = new TestProto
  testProto.codec = TestCodec
  testProto.handler = handle
  switch1.mount(testProto)

  (switch2, peerInfo2) = createSwitch(ma2)
  awaiters.add(await switch1.start())
  awaiters.add(await switch2.start())
  # await switch2.connect(switch1.peerInfo)
  # await switch2.connect(switch1.peerInfo)

  try:
    var conn = await switch2.dial(switch1.peerInfo, TestCodec)
    await conn.writeLp("Hello")
    var msg = await conn.readLp()
    echo "RECEIVED ", cast[string](msg)
    await conn.close()

    # await allFutures(switch2.stop(), switch1.stop())
    # await allFutures(awaiters)
    # await switch2.disconnect(switch1.peerInfo)
    # await switch2.connections[switch1.peerInfo.id].close()
    # GC_fullCollect()

    await sleepAsync(1.minutes)

  except CatchableError as exc:
    echo "Exception ", exc.msg

when isMainModule:
  suite "Mplex tests":
    test "Mplex freeze after stream get closed remotely test":
      check waitFor(testSwitch()) == true
