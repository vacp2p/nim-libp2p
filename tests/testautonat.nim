import std/options
import chronos
import
  ../libp2p/[
    builders,
    protocols/connectivity/autonat
  ],
  ./helpers

proc createAutonatSwitch(): Switch =
  result = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withAutonat()
    .withNoise()
    .build()

proc makeAutonatServicePrivate(): Switch =
  var autonatProtocol = new LPProtocol
  autonatProtocol.handler = proc (conn: Connection, proto: string) {.async, gcsafe.} =
    discard await conn.readLp(1024)
    await conn.writeLp(AutonatDialResponse(
      status: DialError,
      text: some("dial failed"),
      ma: none(MultiAddress)).encode().buffer)
    await conn.close()
  autonatProtocol.codec = AutonatCodec
  result = newStandardSwitch()
  result.mount(autonatProtocol)

suite "Autonat":
  teardown:
    checkTrackers()

  asyncTest "dialMe returns public address":
    let
      src = newStandardSwitch()
      dst = createAutonatSwitch()
    await src.start()
    await dst.start()

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let ma = await Autonat.new(src).dialMe(dst.peerInfo.peerId, dst.peerInfo.addrs)
    check ma == src.peerInfo.addrs[0]
    await allFutures(src.stop(), dst.stop())

  asyncTest "dialMe handles dial error msg":
    let
      src = newStandardSwitch()
      dst = makeAutonatServicePrivate()

    await src.start()
    await dst.start()

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    expect AutonatUnreachableError:
      discard await Autonat.new(src).dialMe(dst.peerInfo.peerId, dst.peerInfo.addrs)
    await allFutures(src.stop(), dst.stop())
