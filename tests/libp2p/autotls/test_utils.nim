# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import net, chronos
import ../../../libp2p/[autotls/utils, autotls/acme/api, autotls/acme/client]
import ../../tools/[unittest, resolver]

suite "AutoTLS DNS records":
  const
    BaseDomain = api.Domain("k51qzi5uqu5dhkzk3z.libp2p.direct")
    AcmeChallengeName = "_acme-challenge.k51qzi5uqu5dhkzk3z.libp2p.direct"
    Ip4Name = "100-10-10-3.k51qzi5uqu5dhkzk3z.libp2p.direct"
    KeyAuth = KeyAuthorization("expected-key-authorization")
    OtherKeyAuth = KeyAuthorization("another-key-authorization")

  let ipAddress = parseIpAddress("100.10.10.3")

  var resolver {.threadvar.}: StubNameResolver

  asyncTeardown:
    checkTrackers()

  asyncSetup:
    resolver =
      StubNameResolver.new(txtRecords = @[KeyAuth], ipAddresses = @["100.10.10.3"])

  asyncTest "matching TXT and a published A record report the records as set":
    let dnsSet = await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 0, retryTime = 0.seconds
    )
    check dnsSet == true

  asyncTest "a TXT record holding another key authorization is not accepted":
    resolver.txtScript = @[@[OtherKeyAuth]]

    let dnsSet = await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 0, retryTime = 0.seconds
    )
    check dnsSet == false

  asyncTest "a matching TXT record without an A record is not accepted":
    resolver.ipAddresses = @[]

    let dnsSet = await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 0, retryTime = 0.seconds
    )
    check dnsSet == false

  asyncTest "an absent TXT record is not accepted":
    resolver.txtScript = @[@[]]

    let dnsSet = await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 0, retryTime = 0.seconds
    )
    check dnsSet == false

  asyncTest "the challenge name and the dashed-IP name are the names queried":
    discard await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 0, retryTime = 0.seconds
    )

    check:
      resolver.txtQueries == @[AcmeChallengeName]
      resolver.ipQueries == @[Ip4Name]

  asyncTest "stops at the first attempt that sees both records":
    let dnsSet = await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 10, retryTime = 0.seconds
    )

    check:
      dnsSet == true
      resolver.txtQueries.len == 1
      resolver.ipQueries.len == 1

  asyncTest "a TXT record that only appears on a later attempt is accepted":
    resolver.txtScript = @[@[], @[KeyAuth]]

    let dnsSet = await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 10, retryTime = 0.seconds
    )

    check:
      dnsSet == true
      resolver.txtQueries.len == 2

  asyncTest "an A record resolved on an earlier attempt is not carried over":
    resolver.txtScript = @[@[], @[KeyAuth]]
    resolver.ipScript =
      @[StubNameResolverIpOutcome.Resolve, StubNameResolverIpOutcome.RaiseAddressError]

    let dnsSet = await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 10, retryTime = 0.seconds
    )
    check dnsSet == false

  asyncTest "retries until both records are seen on the same attempt":
    # Only the third attempt sees the two together.
    resolver.txtScript = @[@[KeyAuth], @[], @[KeyAuth]]
    resolver.ipScript = @[
      StubNameResolverIpOutcome.RaiseAddressError, StubNameResolverIpOutcome.Resolve,
      StubNameResolverIpOutcome.Resolve,
    ]

    let dnsSet = await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 10, retryTime = 0.seconds
    )

    check:
      dnsSet == true
      resolver.txtQueries.len == 3
      resolver.ipQueries.len == 3

  asyncTest "waits retryTime before each retry":
    resolver.txtScript = @[@[]]

    let start = Moment.now()
    let dnsSet = await checkDNSRecords(
      resolver,
      ipAddress,
      BaseDomain,
      KeyAuth,
      retries = 4,
      retryTime = 200.milliseconds,
    )
    let elapsed = Moment.now() - start

    # retries = 4 is 5 total attempts with a delay before each retry, so 4 x 200ms.
    check:
      dnsSet == false
      elapsed >= 700.milliseconds

  asyncTest "an A record that never resolves is not accepted":
    resolver.ipScript = @[StubNameResolverIpOutcome.RaiseAddressError]

    let dnsSet = await checkDNSRecords(
      resolver, ipAddress, BaseDomain, KeyAuth, retries = 3, retryTime = 0.seconds
    )
    check dnsSet == false

  asyncTest "cancellation while resolving the A record propagates":
    resolver.ipScript = @[StubNameResolverIpOutcome.RaiseCancelled]

    expect(CancelledError):
      discard await checkDNSRecords(
        resolver, ipAddress, BaseDomain, KeyAuth, retries = 3, retryTime = 0.seconds
      )

  asyncTest "an IPv6 address is queried with its colons dashed":
    discard await checkDNSRecords(
      resolver,
      parseIpAddress("2001:db8::1"),
      BaseDomain,
      KeyAuth,
      retries = 0,
      retryTime = 0.seconds,
    )

    check resolver.ipQueries == @["2001-db8--1.k51qzi5uqu5dhkzk3z.libp2p.direct"]

  asyncTest "a leading or trailing colon becomes a 0 in the queried name":
    # a seq variable, not an array literal: await over an array literal segfaults on Nim devel refc
    let ips = @["::1", "2001:db8::", "::"]
    for ip in ips:
      discard await checkDNSRecords(
        resolver,
        parseIpAddress(ip),
        BaseDomain,
        KeyAuth,
        retries = 0,
        retryTime = 0.seconds,
      )

    check resolver.ipQueries ==
      @["0--1." & BaseDomain, "2001-db8--0." & BaseDomain, "0--0." & BaseDomain]
