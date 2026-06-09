{.used.}

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, net
import
  ../../../libp2p/[
    switch,
    transports/tcptransport,
    upgrademngrs/upgrade,
    builders,
    protocols/connectivity/autonatv2/types,
    protocols/connectivity/autonatv2/server,
    protocols/connectivity/autonatv2/utils,
    protocols/connectivity/autonatv2/client,
    protocols/connectivity/autonatv2/mockserver,
  ]
import ../../tools/[unittest, crypto, switch_builder, multiaddress]

proc setupAutonat(
    srcAddrs: seq[MultiAddress] = newSeq[MultiAddress](),
    config: AutonatV2Config = AutonatV2Config.new(),
): Future[(Switch, Switch, AutonatV2Client)] {.async.} =
  var srcBuilder = makeStandardSwitchBuilder(TcpAutoAddress)
  if srcAddrs.len > 0:
    srcBuilder = srcBuilder.withAddresses(srcAddrs)

  let
    src = srcBuilder.build()
    dst = makeStandardSwitchBuilder(TcpAutoAddress).withAutonatV2Server(config).build()
    client = AutonatV2Client.new(rng())

  client.setup(src)
  src.mount(client)
  await src.start()
  await dst.start()

  await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
  (src, dst, client)

proc checkedGetIPAddress(): string =
  try:
    $getPrimaryIPAddr()
  except Exception:
    ""

proc checkEncodeDecode[T](msg: T) =
  # this would be equivalent of doing the following (e.g. for DialBack)
  # check msg == DialBack.decode(msg.encode()).get()
  check msg == T.decode(msg.encode()).get()

suite "AutonatV2":
  teardown:
    checkTrackers()

  asyncTest "encode/decode messages":
    # DialRequest
    checkEncodeDecode(
      DialRequest(
        addrs: @[
          MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
          MultiAddress.init("/ip4/127.0.0.1/tcp/4041").get(),
        ],
        nonce: Opt.some(42.uint64),
      )
    )

    # DialResponse
    checkEncodeDecode(
      DialResponse(
        status: Opt.some(ResponseStatus.Ok),
        addrIdx: Opt.some(1.uint32),
        dialStatus: Opt.some(DialStatus.Ok),
      )
    )

    # DialDataRequest
    checkEncodeDecode(
      DialDataRequest(addrIdx: Opt.some(42.AddrIdx), numBytes: Opt.some(128.uint64))
    )

    # DialDataResponse
    checkEncodeDecode(DialDataResponse(data: Opt.some(@[1'u8, 2, 3, 4, 5])))

    # AutonatV2Msg - DialRequest
    checkEncodeDecode(
      AutonatV2Msg(
        dialReq: Opt.some(
          DialRequest(
            addrs: @[
              MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
              MultiAddress.init("/ip4/127.0.0.1/tcp/4041").get(),
            ],
            nonce: Opt.some(42.uint64),
          )
        )
      )
    )

    # AutonatV2Msg - DialResponse
    checkEncodeDecode(
      AutonatV2Msg(
        dialResp: Opt.some(
          DialResponse(
            status: Opt.some(ResponseStatus.Ok),
            addrIdx: Opt.some(1.uint32),
            dialStatus: Opt.some(DialStatus.Ok),
          )
        )
      )
    )

    # AutonatV2Msg - DialDataRequest
    checkEncodeDecode(
      AutonatV2Msg(
        dialDataReq: Opt.some(
          DialDataRequest(addrIdx: Opt.some(42.AddrIdx), numBytes: Opt.some(128.uint64))
        )
      )
    )

    # AutonatV2Msg - DialDataResponse
    checkEncodeDecode(
      AutonatV2Msg(
        dialDataResp: Opt.some(DialDataResponse(data: Opt.some(@[1'u8, 2, 3, 4, 5])))
      )
    )

    # DialBack
    checkEncodeDecode(DialBack(nonce: Opt.some(123456.uint64)))

    # DialBackResponse
    checkEncodeDecode(DialBackResponse(status: Opt.some(DialBackStatus.Ok)))

  asyncTest "asNetworkReachability":
    check asNetworkReachability(DialResponse(status: Opt.some(EInternalError))) ==
      Unknown
    check asNetworkReachability(DialResponse(status: Opt.some(ERequestRejected))) ==
      Unknown
    check asNetworkReachability(DialResponse(status: Opt.some(EDialRefused))) == Unknown
    check asNetworkReachability(
      DialResponse(
        status: Opt.some(ResponseStatus.Ok), dialStatus: Opt.none(DialStatus)
      )
    ) == Unknown
    check asNetworkReachability(
      DialResponse(status: Opt.some(ResponseStatus.Ok), dialStatus: Opt.some(Unused))
    ) == Unknown
    check asNetworkReachability(
      DialResponse(
        status: Opt.some(ResponseStatus.Ok), dialStatus: Opt.some(EDialError)
      )
    ) == NotReachable
    check asNetworkReachability(
      DialResponse(
        status: Opt.some(ResponseStatus.Ok), dialStatus: Opt.some(EDialBackError)
      )
    ) == NotReachable
    check asNetworkReachability(
      DialResponse(
        status: Opt.some(ResponseStatus.Ok), dialStatus: Opt.some(DialStatus.Ok)
      )
    ) == Reachable

  asyncTest "asAutonatV2Response":
    let addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/4000").get()]
    let errorDialResp = DialResponse(
      status: Opt.some(ResponseStatus.Ok),
      addrIdx: Opt.none(AddrIdx),
      dialStatus: Opt.none(DialStatus),
    )
    check asAutonatV2Response(errorDialResp, addrs) ==
      AutonatV2Response(
        reachability: Unknown, dialResp: errorDialResp, addrs: Opt.none(MultiAddress)
      )

    let correctDialResp = DialResponse(
      status: Opt.some(ResponseStatus.Ok),
      addrIdx: Opt.some(0.AddrIdx),
      dialStatus: Opt.some(DialStatus.Ok),
    )
    check asAutonatV2Response(correctDialResp, addrs) ==
      AutonatV2Response(
        reachability: Reachable, dialResp: correctDialResp, addrs: Opt.some(addrs[0])
      )

  asyncTest "Instantiate server":
    let serverSwitch = makeStandardSwitchBuilder().withAutonatV2Server().build()
    await serverSwitch.start()
    await serverSwitch.stop()

  asyncTest "Instantiate server with config":
    let serverSwitch = makeStandardSwitchBuilder()
      .withAutonatV2Server(AutonatV2Config.new(allowPrivateAddresses = true))
      .build()

    await serverSwitch.start()
    await serverSwitch.stop()

  asyncTest "Successful DialRequest":
    let (src, dst, client) =
      await setupAutonat(config = AutonatV2Config.new(allowPrivateAddresses = true))
    defer:
      await allFutures(src.stop(), dst.stop())

    check (await client.sendDialRequest(dst.peerInfo.peerId, src.peerInfo.addrs)) ==
      AutonatV2Response(
        reachability: Reachable,
        dialResp: DialResponse(
          status: Opt.some(ResponseStatus.Ok),
          dialStatus: Opt.some(DialStatus.Ok),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(src.peerInfo.addrs[0]),
      )

  asyncTest "Successful DialRequest with amplification attack prevention":
    # use ip address other than 127.0.0.1 for client
    let
      listenAddrs = @[
        MultiAddress.init("/ip4/" & checkedGetIPAddress() & "/tcp/4040").get(),
        MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
      ]
      reqAddrs = @[listenAddrs[0]]
      (src, dst, client) = await setupAutonat(srcAddrs = listenAddrs)
    defer:
      await allFutures(src.stop(), dst.stop())

    check (await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)) ==
      AutonatV2Response(
        reachability: Reachable,
        dialResp: DialResponse(
          status: Opt.some(ResponseStatus.Ok),
          dialStatus: Opt.some(DialStatus.Ok),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(src.peerInfo.addrs[0]),
      )

  asyncTest "Failed DialRequest":
    let (src, dst, client) =
      await setupAutonat(config = AutonatV2Config.new(dialTimeout = 1.seconds))
    defer:
      await allFutures(src.stop(), dst.stop())

    check (
      await client.sendDialRequest(
        dst.peerInfo.peerId, @[MultiAddress.init("/ip4/1.1.1.1/tcp/4040").get()]
      )
    ) ==
      AutonatV2Response(
        reachability: NotReachable,
        dialResp: DialResponse(
          status: Opt.some(ResponseStatus.Ok),
          dialStatus: Opt.some(DialStatus.EDialError),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(MultiAddress.init("/ip4/1.1.1.1/tcp/4040").get()),
      )

  asyncTest "Failed DialRequest with amplification attack prevention":
    # use ip address other than 127.0.0.1 for client
    let
      listenAddrs = @[
        MultiAddress.init("/ip4/" & checkedGetIPAddress() & "/tcp/4040").get(),
        MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
      ]
      reqAddrs = @[MultiAddress.init("/ip4/1.1.1.1/tcp/4040").get()]
      (src, dst, client) = await setupAutonat(
        srcAddrs = listenAddrs, config = AutonatV2Config.new(dialTimeout = 1.seconds)
      )
    defer:
      await allFutures(src.stop(), dst.stop())

    check (await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)) ==
      AutonatV2Response(
        reachability: NotReachable,
        dialResp: DialResponse(
          status: Opt.some(ResponseStatus.Ok),
          dialStatus: Opt.some(DialStatus.EDialError),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(reqAddrs[0]),
      )

  asyncTest "Server responding with invalid messages":
    let
      src = makeStandardSwitch()
      dst = makeStandardSwitch()
      client = AutonatV2Client.new(rng())
      autonatV2Mock = AutonatV2Mock.new()
      reqAddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get()]

    client.setup(src)
    dst.mount(autonatV2Mock)
    src.mount(client)
    await src.start()
    await dst.start()
    defer:
      await allFutures(src.stop(), dst.stop())

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)

    # 1. invalid autonatv2msg
    autonatV2Mock.response =
      DialBackResponse(status: Opt.some(DialBackStatus.Ok)).encode()
    expect(AutonatV2Error):
      discard await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)

    # 2. msg that is not DialResponse or DialDataRequest
    autonatV2Mock.response = AutonatV2Msg(
      dialReq: Opt.some(DialRequest(addrs: @[], nonce: Opt.some(0.uint64)))
    ).encode()
    expect(AutonatV2Error):
      discard await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)

    # 3. invalid addrIdx (e.g. 1000 when only 1 is present)
    autonatV2Mock.response = AutonatV2Msg(
      dialResp: Opt.some(
        DialResponse(
          status: Opt.some(ResponseStatus.Ok),
          addrIdx: Opt.some(1000.AddrIdx),
          dialStatus: Opt.some(DialStatus.Ok),
        )
      )
    ).encode()
    expect(AutonatV2Error):
      discard await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)
