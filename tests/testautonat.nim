import std/options
import chronos
import
  ../libp2p/[
    transports/tcptransport,
    upgrademngrs/upgrade,
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
    check ma in src.peerInfo.addrs
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

  asyncTest "Timeout is triggered in autonat handle":
    let
      src = newStandardSwitch()
      dst = newStandardSwitch()
      autonat = Autonat.new(dst, dialTimeout = 1.seconds)
      doesNothingListener = TcpTransport.new(upgrade = Upgrade())

    dst.mount(autonat)
    await src.start()
    await dst.start()
    await doesNothingListener.start(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let conn = await src.dial(dst.peerInfo.peerId, @[AutonatCodec])
    let buffer = AutonatDial(peerInfo: some(AutonatPeerInfo(
                         id: some(src.peerInfo.peerId),
                         # we ask to be dialed in the does nothing listener instead
                         addrs: doesNothingListener.addrs
                       ))).encode().buffer
    await conn.writeLp(buffer)
    let response = AutonatMsg.decode(await conn.readLp(1024)).get().response.get()
    check:
      response.status == DialError
      response.text.get() == "Timeout exceeded!"
      response.ma.isNone()
    await allFutures(doesNothingListener.stop(), src.stop(), dst.stop())
