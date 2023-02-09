import std/options
import chronos
import
  ../libp2p/[
    transports/tcptransport,
    upgrademngrs/upgrade,
    builders,
    protocols/connectivity/autonat/client,
    protocols/connectivity/autonat/server,
    nameresolving/nameresolver,
    nameresolving/mockresolver,
  ],
  ./helpers

proc createAutonatSwitch(nameResolver: NameResolver = nil): Switch =
  var builder = SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withAutonat()
    .withNoise()

  if nameResolver != nil:
    builder = builder.withNameResolver(nameResolver)

  return builder.build()

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
    let ma = await AutonatClient.new().dialMe(src, dst.peerInfo.peerId, dst.peerInfo.addrs)
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
      discard await AutonatClient.new().dialMe(src, dst.peerInfo.peerId, dst.peerInfo.addrs)
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
      response.text.get() == "Dial timeout"
      response.ma.isNone()
    await allFutures(doesNothingListener.stop(), src.stop(), dst.stop())

  asyncTest "dialMe dials dns and returns public address":
    let resolver = MockResolver.new()
    resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
    resolver.ipResponses[("localhost", true)] = @["::1"]

    let
      src = newStandardSwitch()
      dst = createAutonatSwitch(nameResolver = resolver)

    await src.start()
    await dst.start()

    let testAddr = MultiAddress.init("/dns4/localhost/").tryGet() &
                    dst.peerInfo.addrs[0][1].tryGet()

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let ma = await AutonatClient.new().dialMe(src, dst.peerInfo.peerId, @[testAddr])

    check ma in src.peerInfo.addrs
    await allFutures(src.stop(), dst.stop())
