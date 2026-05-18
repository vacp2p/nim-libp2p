# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import
  ../../../libp2p/[
    transports/tcptransport,
    upgrademngrs/upgrade,
    builders,
    protocols/connectivity/autonat/client,
    protocols/connectivity/autonat/server,
    nameresolving/nameresolver,
    nameresolving/mockresolver,
  ]
import ../../tools/[unittest, crypto, switch_builder]

proc makeAutonatSwitch(nameResolver: NameResolver = nil): Switch =
  return SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
    .withTcpTransport()
    .withMplex()
    .withAutonat()
    .withNoise()
    .withNameResolver(nameResolver)
    .build()

proc makeSwitch(): Switch =
  return makeStandardSwitch(transport = TransportType.TCP)

proc makeAutonatServicePrivate(): Switch =
  var autonatProtocol = new LPProtocol
  autonatProtocol.handler = proc(
      stream: Stream, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      discard await stream.readLp(1024)
      await stream.writeLp(
        AutonatDialResponse(
          status: DialError, text: Opt.some("dial failed"), ma: Opt.none(MultiAddress)
        ).encode().buffer
      )
    except LPStreamError:
      raiseAssert "Unexpected LPStreamError in autonat private service handler"
    finally:
      await stream.close()
  autonatProtocol.codec = AutonatCodec
  result = makeSwitch()
  result.mount(autonatProtocol)

suite "Autonat":
  teardown:
    checkTrackers()

  asyncTest "dialMe returns public address":
    let
      src = makeSwitch()
      dst = makeAutonatSwitch()
    await src.start()
    await dst.start()

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let ma =
      await AutonatClient.new().dialMe(src, dst.peerInfo.peerId, dst.peerInfo.addrs)
    check ma in src.peerInfo.addrs
    await allFutures(src.stop(), dst.stop())

  asyncTest "dialMe handles dial error msg":
    let
      src = makeSwitch()
      dst = makeAutonatServicePrivate()

    await src.start()
    await dst.start()

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    expect AutonatUnreachableError:
      discard
        await AutonatClient.new().dialMe(src, dst.peerInfo.peerId, dst.peerInfo.addrs)
    await allFutures(src.stop(), dst.stop())

  asyncTest "Timeout is triggered in autonat handle":
    let
      src = makeSwitch()
      dst = makeSwitch()
      autonat = Autonat.new(dst, dialTimeout = 1.seconds)
      doesNothingListener = TcpTransport.new(upgrade = Upgrade())

    dst.mount(autonat)
    await src.start()
    await dst.start()
    await doesNothingListener.start(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let stream = await src.dial(dst.peerInfo.peerId, @[AutonatCodec])
    let buffer = AutonatDial(
      peerInfo: Opt.some(
        AutonatPeerInfo(
          id: Opt.some(src.peerInfo.peerId),
          # we ask to be dialed in the does nothing listener instead
          addrs: doesNothingListener.addrs,
        )
      )
    ).encode().buffer
    await stream.writeLp(buffer)
    let response = AutonatMsg.decode(await stream.readLp(1024)).get().response.get()
    check:
      response.status == DialError
      response.text.get() == "Dial timeout"
      response.ma.isNone()
    await allFutures(doesNothingListener.stop(), src.stop(), dst.stop())

  asyncTest "dialMe dials dns and returns public address":
    let
      src = makeSwitch()
      dst = makeAutonatSwitch(nameResolver = MockResolver.default())

    await src.start()
    await dst.start()

    let testAddr =
      MultiAddress.init("/dns4/localhost/").tryGet() & dst.peerInfo.addrs[0][1].tryGet()

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let ma = await AutonatClient.new().dialMe(src, dst.peerInfo.peerId, @[testAddr])

    check ma in src.peerInfo.addrs
    await allFutures(src.stop(), dst.stop())
