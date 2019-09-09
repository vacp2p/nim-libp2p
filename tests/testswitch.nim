import unittest, tables
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
       ../libp2p/muxers/mplex/types

const TestCodec = "/test/proto/1.0.0"

type
  TestProto = ref object of LPProtocol

method init(p: TestProto) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} = 
    let msg = cast[string](await conn.readLp())
    check "Hello!" == msg
    await conn.writeLp("Hello!")
    await conn.close()

  p.codec = TestCodec
  p.handler = handle

suite "Switch":
  test "e2e use switch": 
    proc createSwitch(ma: MultiAddress): (Switch, PeerInfo) =
      let seckey = PrivateKey.random(RSA)
      var peerInfo: PeerInfo
      peerInfo.peerId = PeerID.init(seckey)
      peerInfo.addrs.add(ma)
      let identify = newIdentify(peerInfo)

      proc createMplex(conn: Connection): Muxer =
        result = newMplex(conn)

      let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
      let transports = @[Transport(newTransport(TcpTransport))]
      let muxers = [(MplexCodec, mplexProvider)].toTable()
      let switch = newSwitch(peerInfo, transports, identify, muxers)
      result = (switch, peerInfo)

    proc testSwitch(): Future[bool] {.async, gcsafe.} =
      let ma1: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53370")
      let ma2: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53371")

      var peerInfo1, peerInfo2: PeerInfo
      var switch1, switch2: Switch
      (switch1, peerInfo1) = createSwitch(ma1)

      let testProto = new TestProto
      testProto.init()
      testProto.codec = TestCodec
      switch1.mount(testProto)
      await switch1.start()

      (switch2, peerInfo2) = createSwitch(ma2)
      await switch2.start()
      let conn = await switch2.dial(peerInfo1, TestCodec)
      debug "TEST SWITCH: dial succesful"
      await conn.writeLp("Hello!")
      let msg = cast[string](await conn.readLp())
      check "Hello!" == msg

      result = true
      await allFutures(switch1.stop(), switch2.stop())

    check:
      waitFor(testSwitch()) == true
