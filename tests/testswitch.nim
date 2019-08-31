import unittest
import chronos
import ../libp2p/switch, ../libp2p/multistream,
       ../libp2p/identify, ../libp2p/connection,
       ../libp2p/transport, ../libp2p/tcptransport,
       ../libp2p/multiaddress, ../libp2p/peerinfo,
       ../libp2p/crypto/crypto, ../libp2p/peer,
       ../libp2p/protocol

const TestCodec = "/test/proto/1.0.0"

type
  TestProto = ref object of LPProtocol

method init(p: TestProto) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} = 
    let msg = cast[string](await conn.readLp())
    check "Hello!" == msg
    await conn.writeLp("Hello!")

  p.codec = TestCodec
  p.handler = handle

suite "Switch":
  test "e2e use switch": 
    proc testSwitch(): Future[bool] {.async, gcsafe.} =
      let ma1: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53370")
      let ma2: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53371")

      var peerInfo1, peerInfo2: PeerInfo
      var switch1, switch2: Switch
      proc createSwitch(ma: MultiAddress): (Switch, PeerInfo) =
        let seckey = PrivateKey.random(RSA)
        var peerInfo: PeerInfo
        peerInfo.peerId = PeerID.init(seckey)
        peerInfo.addrs.add(ma)
        let switch = newSwitch(peerInfo, @[Transport(newTransport(TcpTransport))])
        result = (switch, peerInfo)

      (switch1, peerInfo1) = createSwitch(ma1)
      let testProto = newProtocol(TestProto, peerInfo1)
      switch1.mount(testProto)
      await switch1.start()

      (switch2, peerInfo2) = createSwitch(ma2)
      let conn = await switch2.dial(peerInfo1, TestCodec)
      await conn.writeLp("Hello!")
      let msg = cast[string](await conn.readLp())
      check "Hello!" == msg

      result = true

    check:
      waitFor(testSwitch()) == true
