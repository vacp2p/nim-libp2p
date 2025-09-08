{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/options, net
import chronos
import
  ../libp2p/[
    switch,
    transports/tcptransport,
    upgrademngrs/upgrade,
    builders,
    protocols/connectivity/autonatv2/types,
    protocols/connectivity/autonatv2/server,
    protocols/connectivity/autonatv2/utils,
    protocols/connectivity/autonatv2/client,
  ],
  ./helpers

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
        addrs:
          @[
            MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
            MultiAddress.init("/ip4/127.0.0.1/tcp/4041").get(),
          ],
        nonce: 42,
      )
    )

    # DialResponse
    checkEncodeDecode(
      DialResponse(
        status: ResponseStatus.Ok,
        addrIdx: Opt.some(1.uint32),
        dialStatus: Opt.some(DialStatus.Ok),
      )
    )

    # DialDataRequest
    checkEncodeDecode(DialDataRequest(addrIdx: 42, numBytes: 128))

    # DialDataResponse
    checkEncodeDecode(DialDataResponse(data: @[1'u8, 2, 3, 4, 5]))

    # AutonatV2Msg - DialRequest
    checkEncodeDecode(
      AutonatV2Msg(
        msgType: MsgType.DialRequest,
        dialReq: DialRequest(
          addrs:
            @[
              MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
              MultiAddress.init("/ip4/127.0.0.1/tcp/4041").get(),
            ],
          nonce: 42,
        ),
      )
    )

    # AutonatV2Msg - DialResponse
    checkEncodeDecode(
      AutonatV2Msg(
        msgType: MsgType.DialResponse,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          addrIdx: Opt.some(1.uint32),
          dialStatus: Opt.some(DialStatus.Ok),
        ),
      )
    )

    # AutonatV2Msg - DialDataRequest
    checkEncodeDecode(
      AutonatV2Msg(
        msgType: MsgType.DialDataRequest,
        dialDataReq: DialDataRequest(addrIdx: 42, numBytes: 128),
      )
    )

    # AutonatV2Msg - DialDataResponse
    checkEncodeDecode(
      AutonatV2Msg(
        msgType: MsgType.DialDataResponse,
        dialDataResp: DialDataResponse(data: @[1'u8, 2, 3, 4, 5]),
      )
    )

    # DialBack
    checkEncodeDecode(DialBack(nonce: 123456))

    # DialBackResponse
    checkEncodeDecode(DialBackResponse(status: DialBackStatus.Ok))

  asyncTest "asNetworkReachability":
    check asNetworkReachability(DialResponse(status: EInternalError)) == Unknown
    check asNetworkReachability(DialResponse(status: ERequestRejected)) == Unknown
    check asNetworkReachability(DialResponse(status: EDialRefused)) == Unknown
    check asNetworkReachability(
      DialResponse(status: ResponseStatus.Ok, dialStatus: Opt.none(DialStatus))
    ) == Unknown
    check asNetworkReachability(
      DialResponse(status: ResponseStatus.Ok, dialStatus: Opt.some(Unused))
    ) == Unknown
    check asNetworkReachability(
      DialResponse(status: ResponseStatus.Ok, dialStatus: Opt.some(EDialError))
    ) == NotReachable
    check asNetworkReachability(
      DialResponse(status: ResponseStatus.Ok, dialStatus: Opt.some(EDialBackError))
    ) == NotReachable
    check asNetworkReachability(
      DialResponse(status: ResponseStatus.Ok, dialStatus: Opt.some(DialStatus.Ok))
    ) == Reachable

  asyncTest "asAutonatV2Response":
    let addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/4000").get()]
    let errorDialResp = DialResponse(
      status: ResponseStatus.Ok,
      addrIdx: Opt.none(AddrIdx),
      dialStatus: Opt.none(DialStatus),
    )
    check asAutonatV2Response(errorDialResp, addrs) ==
      AutonatV2Response(
        reachability: Unknown, dialResp: errorDialResp, addrs: Opt.none(MultiAddress)
      )

    let correctDialResp = DialResponse(
      status: ResponseStatus.Ok,
      addrIdx: Opt.some(0.AddrIdx),
      dialStatus: Opt.some(DialStatus.Ok),
    )
    check asAutonatV2Response(correctDialResp, addrs) ==
      AutonatV2Response(
        reachability: Reachable, dialResp: correctDialResp, addrs: Opt.some(addrs[0])
      )

  asyncTest "Instantiate server":
    let serverSwitch = newStandardSwitchBuilder().withAutonatV2().build()
    await serverSwitch.start()
    await serverSwitch.stop()

  asyncTest "Instantiate server with config":
    let serverSwitch = newStandardSwitchBuilder()
      .withAutonatV2(config = AutonatV2Config.new(allowPrivateAddresses = true))
      .build()

    await serverSwitch.start()
    await serverSwitch.stop()

  asyncTest "Successful DialRequest":
    let
      src = newStandardSwitchBuilder().build()
      dst = newStandardSwitchBuilder()
        .withAutonatV2(config = AutonatV2Config.new(allowPrivateAddresses = true))
        .build()

    let client = AutonatV2Client.new(src, newRng())
    src.mount(client)
    await src.start()
    await dst.start()

    defer:
      await allFutures(src.stop(), dst.stop())

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let autonatV2Resp = await client.sendDialRequest(
      dst.peerInfo.peerId, dst.peerInfo.addrs, src.peerInfo.addrs
    )

    check autonatV2Resp ==
      AutonatV2Response(
        reachability: Reachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.Ok),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(src.peerInfo.addrs[0]),
      )

  asyncTest "Successful DialRequest with amplification attack prevention":
    # use ip address other than 127.0.0.1 for client
    let
      listenAddrs =
        @[
          MultiAddress.init("/ip4/" & $getPrimaryIPAddr() & "/tcp/4040").get(),
          MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
        ]
      reqAddrs = @[listenAddrs[0]]
      src = newStandardSwitchBuilder(addrs = listenAddrs).build()
      dst = newStandardSwitchBuilder().withAutonatV2().build()

    let client = AutonatV2Client.new(src, newRng())
    src.mount(client)
    await src.start()
    await dst.start()

    defer:
      await allFutures(src.stop(), dst.stop())

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let autonatV2Resp =
      await client.sendDialRequest(dst.peerInfo.peerId, dst.peerInfo.addrs, reqAddrs)

    check autonatV2Resp ==
      AutonatV2Response(
        reachability: Reachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.Ok),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(src.peerInfo.addrs[0]),
      )

  asyncTest "Failed DialRequest":
    let
      src = newStandardSwitchBuilder().build()
      dst = newStandardSwitchBuilder()
        .withAutonatV2(config = AutonatV2Config.new(dialTimeout = 1.seconds))
        .build()

    let client = AutonatV2Client.new(src, newRng())
    src.mount(client)
    await src.start()
    await dst.start()

    defer:
      await allFutures(src.stop(), dst.stop())

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let autonatV2Resp = await client.sendDialRequest(
      dst.peerInfo.peerId,
      dst.peerInfo.addrs,
      @[MultiAddress.init("/ip4/1.1.1.1/tcp/4040").get()],
    )

    check autonatV2Resp ==
      AutonatV2Response(
        reachability: NotReachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.EDialError),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(MultiAddress.init("/ip4/1.1.1.1/tcp/4040").get()),
      )

  asyncTest "Failed DialRequest with amplification attack prevention":
    # use ip address other than 127.0.0.1 for client
    let
      listenAddrs =
        @[
          MultiAddress.init("/ip4/" & $getPrimaryIPAddr() & "/tcp/4040").get(),
          MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
        ]
      reqAddrs = @[MultiAddress.init("/ip4/1.1.1.1/tcp/4040").get()]
      src = newStandardSwitchBuilder(addrs = listenAddrs).build()
      dst = newStandardSwitchBuilder()
        .withAutonatV2(config = AutonatV2Config.new(dialTimeout = 1.seconds))
        .build()

    let client = AutonatV2Client.new(src, newRng())
    src.mount(client)
    await src.start()
    await dst.start()

    defer:
      await allFutures(src.stop(), dst.stop())

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    let autonatV2Resp =
      await client.sendDialRequest(dst.peerInfo.peerId, dst.peerInfo.addrs, reqAddrs)

    check autonatV2Resp ==
      AutonatV2Response(
        reachability: NotReachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.EDialError),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(MultiAddress.init("/ip4/1.1.1.1/tcp/4040").get()),
      )
