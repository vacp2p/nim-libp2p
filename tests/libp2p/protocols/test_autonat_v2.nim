{.used.}

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, net, sequtils
import
  ../../../libp2p/[
    switch,
    multiaddress,
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
    srcAddrs: seq[MultiAddress] = @[TcpAutoAddress],
    dstAddrs: seq[MultiAddress] = @[TcpAutoAddress],
    config: AutonatV2Config = AutonatV2Config.new(),
): Future[(Switch, Switch, AutonatV2Client)] {.async.} =
  let
    src = makeStandardSwitchBuilder(srcAddrs).build()
    dst = makeStandardSwitchBuilder(dstAddrs).withAutonatV2Server(config).build()
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

suite "AutonatV2":
  teardown:
    checkTrackers()

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
    let addrs = @[ma("/ip4/127.0.0.1/tcp/4000")]
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

    let missingAddrDialResp = DialResponse(
      status: ResponseStatus.Ok,
      addrIdx: Opt.some(1.AddrIdx),
      dialStatus: Opt.none(DialStatus),
    )
    check asAutonatV2Response(missingAddrDialResp, addrs) ==
      AutonatV2Response(
        reachability: Unknown,
        dialResp: missingAddrDialResp,
        addrs: Opt.none(MultiAddress),
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
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.Ok),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(src.peerInfo.addrs[0]),
      )

  asyncTest "Successful DialRequest with amplification attack prevention":
    # use ip address other than 127.0.0.1 for client
    let
      listenAddrs = @[
        ma("/ip4/" & checkedGetIPAddress() & "/tcp/4040"), ma("/ip4/127.0.0.1/tcp/4040")
      ]
      reqAddrs = @[listenAddrs[0]]
      (src, dst, client) = await setupAutonat(srcAddrs = listenAddrs)
    defer:
      await allFutures(src.stop(), dst.stop())

    check (await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)) ==
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
    let (src, dst, client) =
      await setupAutonat(config = AutonatV2Config.new(dialTimeout = 1.seconds))
    defer:
      await allFutures(src.stop(), dst.stop())

    check (
      await client.sendDialRequest(dst.peerInfo.peerId, @[ma("/ip4/1.1.1.1/tcp/4040")])
    ) ==
      AutonatV2Response(
        reachability: NotReachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.EDialError),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(ma("/ip4/1.1.1.1/tcp/4040")),
      )

  asyncTest "Failed DialRequest with amplification attack prevention":
    # use ip address other than 127.0.0.1 for client
    let
      listenAddrs = @[
        ma("/ip4/" & checkedGetIPAddress() & "/tcp/4040"), ma("/ip4/127.0.0.1/tcp/4040")
      ]
      reqAddrs = @[ma("/ip4/1.1.1.1/tcp/4040")]
      (src, dst, client) = await setupAutonat(
        srcAddrs = listenAddrs, config = AutonatV2Config.new(dialTimeout = 1.seconds)
      )
    defer:
      await allFutures(src.stop(), dst.stop())

    check (await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)) ==
      AutonatV2Response(
        reachability: NotReachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.EDialError),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(reqAddrs[0]),
      )

  asyncTest "DialRequest with IPv6 addr refused by IPv4-only server":
    # server listens on IPv4 only, so it refuses to dial any IPv6 addr
    let (src, dst, client) = await setupAutonat()
    defer:
      await allFutures(src.stop(), dst.stop())

    let reqAddrs = @[ma("/ip6/2001:db8::1/tcp/4040")]
    check (await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)) ==
      AutonatV2Response(
        reachability: Unknown,
        dialResp: DialResponse(
          status: EDialRefused,
          addrIdx: Opt.none(AddrIdx),
          dialStatus: Opt.none(DialStatus),
        ),
        addrs: Opt.none(MultiAddress),
      )

  asyncTest "DialRequest with IPv4 addr refused by IPv6-only server":
    # server listens on IPv6 only, so it refuses to dial any IPv4 addr
    let (src, dst, client) = await setupAutonat(dstAddrs = @[TcpAutoAddressIP6])
    defer:
      await allFutures(src.stop(), dst.stop())

    let reqAddrs = @[ma("/ip4/1.1.1.1/tcp/4040")]
    check (await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)) ==
      AutonatV2Response(
        reachability: Unknown,
        dialResp: DialResponse(
          status: EDialRefused,
          addrIdx: Opt.none(AddrIdx),
          dialStatus: Opt.none(DialStatus),
        ),
        addrs: Opt.none(MultiAddress),
      )

  asyncTest "DialRequest with private IPv6 addr succeeds despite allowPrivateAddresses=false":
    # TODO: nim-libp2p#2710
    # isPrivate classifies every IPv6 address as non-private
    # the server therefore dials back the loopback IPv6 addr instead of refusing it
    let
      dualStackAddrs = @[TcpAutoAddressIP4, TcpAutoAddressIP6]
      (src, dst, client) =
        await setupAutonat(srcAddrs = dualStackAddrs, dstAddrs = dualStackAddrs)
    defer:
      await allFutures(src.stop(), dst.stop())

    # request only the IPv6 listen addr of the client
    let reqAddrs = src.peerInfo.addrs.filterIt(TCP_IP6.match(it))
    check reqAddrs.len == 1

    check (await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)) ==
      AutonatV2Response(
        reachability: Reachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.Ok),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(reqAddrs[0]),
      )

  asyncTest "Amplification attack prevention skipped when observed IPv4 addr matches a requested addr":
    # the requested addr matches the observed addr of the client,
    # so the server dials back right away without demanding dial data
    # dialDataSize is set above what the client accepts to prove the skip:
    # a DialDataRequest would have failed the request with AutonatV2Error
    let (src, dst, client) = await setupAutonat(
      config = AutonatV2Config.new(
        dialDataSize = (MaxAcceptedDialDataRequest + 1).uint64,
        allowPrivateAddresses = true,
      )
    )
    defer:
      await allFutures(src.stop(), dst.stop())

    check (await client.sendDialRequest(dst.peerInfo.peerId, src.peerInfo.addrs)) ==
      AutonatV2Response(
        reachability: Reachable,
        dialResp: DialResponse(
          status: ResponseStatus.Ok,
          dialStatus: Opt.some(DialStatus.Ok),
          addrIdx: Opt.some(0.AddrIdx),
        ),
        addrs: Opt.some(src.peerInfo.addrs[0]),
      )

  asyncTest "Amplification attack prevention not skipped when observed IPv6 addr matches a requested addr":
    # TODO: nim-libp2p#2731
    # the requested addr matches the observed addr of the client,
    # yet the server demands dial data before the dial back
    # dialDataSize is set above what the client accepts to prove the demand:
    # the DialDataRequest fails the request with AutonatV2Error
    let
      ipv6Addrs = @[TcpAutoAddressIP6]
      (src, dst, client) = await setupAutonat(
        srcAddrs = ipv6Addrs,
        dstAddrs = ipv6Addrs,
        config = AutonatV2Config.new(
          dialDataSize = (MaxAcceptedDialDataRequest + 1).uint64,
          allowPrivateAddresses = true,
        ),
      )
    defer:
      await allFutures(src.stop(), dst.stop())

    expect(AutonatV2Error):
      discard await client.sendDialRequest(dst.peerInfo.peerId, src.peerInfo.addrs)

  asyncTest "Server responding with invalid messages":
    let
      src = makeStandardSwitch()
      dst = makeStandardSwitch()
      client = AutonatV2Client.new(rng())
      autonatV2Mock = AutonatV2Mock.new()
      reqAddrs = @[ma("/ip4/127.0.0.1/tcp/4040")]

    client.setup(src)
    dst.mount(autonatV2Mock)
    src.mount(client)
    await src.start()
    await dst.start()
    defer:
      await allFutures(src.stop(), dst.stop())

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)

    # 1. invalid autonatv2msg
    autonatV2Mock.response = DialBackResponse(status: DialBackStatus.Ok).encode()
    expect(AutonatV2Error):
      discard await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)

    # 2. msg that is not DialResponse or DialDataRequest
    autonatV2Mock.response = AutonatV2Msg(
      oneof: AutonatV2MsgOneof(
        kind: MsgKind.DialRequest, dialRequest: DialRequest(addrs: @[], nonce: 0.uint64)
      )
    ).encode()
    expect(AutonatV2Error):
      discard await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)

    # 3. invalid addrIdx (e.g. 1000 when only 1 is present)
    autonatV2Mock.response = AutonatV2Msg(
      oneof: AutonatV2MsgOneof(
        kind: MsgKind.DialResponse,
        dialResponse: DialResponse(
          status: ResponseStatus.Ok,
          addrIdx: Opt.some(1000.AddrIdx),
          dialStatus: Opt.some(DialStatus.Ok),
        ),
      )
    ).encode()
    expect(AutonatV2Error):
      discard await client.sendDialRequest(dst.peerInfo.peerId, reqAddrs)
