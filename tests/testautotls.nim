{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[strformat, net]
import chronos
import chronos/apps/http/httpclient
import
  ../libp2p/[
    stream/connection,
    transports/tcptransport,
    upgrademngrs/upgrade,
    multiaddress,
    switch,
    builders,
    autotls/autotls,
    autotls/acme,
    autotls/utils,
    nameresolving/dnsresolver,
    wire,
  ]

import ./helpers

suite "AutoTLS":
  asyncTest "test ACME":
    let acc = await ACMEAccount.new(KeyPair.random(PKScheme.RSA, newRng()[]).get())
    defer:
      checkTrackers()

    await acc.register()
    # account was registered (kid set)
    check acc.kid.isSome

    # challenge requested
    let (dns01Challenge, finalizeURL, orderURL) =
      await acc.requestChallenge(@["some.dummy.domain.com"])
    check dns01Challenge.isNil == false
    check finalizeURL.len > 0
    check orderURL.len > 0
    await noCancel(acc.session.closeWait())

  asyncTest "test AutoTLSManager":
    let switch = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddress(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
      .withTcpTransport()
      .withAutoTLSManager()
      .withYamux()
      .withNoise()
      .build()

    defer:
      checkTrackers()

    try:
      let hostPrimaryIP = getPrimaryIPAddr()
      if not isPublicIPv4(hostPrimaryIP):
        skip() # host doesn't have public IPv4 address
        return
    except Exception:
      skip() # can't get primary IPv4 address from host
      return

    # this is so that we can check renewal afterwards
    switch.autoTLSMgr.renewCheckTime = 3.seconds

    await switch.start()

    # wait for cert to be ready
    await switch.autoTLSMgr.certReady.wait()
    # clear since we'll use it again
    switch.autoTLSMgr.certReady.clear()

    # challenge was sent (bearer token from peer id auth was set)
    check switch.autoTLSMgr.bearerToken.isSome

    # DNS TXT record is set
    let dnsResolver = DnsResolver.new(
      @[
        initTAddress("1.1.1.1:53"),
        initTAddress("1.0.0.1:53"),
        initTAddress("[2606:4700:4700::1111]:53"),
      ]
    )
    let base36PeerId = encodePeerId(switch.peerInfo.peerId)
    let acmeChalDomain = fmt"_acme-challenge.{base36PeerId}.{AutoTLSDNSServer}"
    let txt = await dnsResolver.resolveTxt(acmeChalDomain)
    check txt.len > 0
    let dnsTXTRecord = txt[0]
    check dnsTXTRecord != "not set yet"

    # certificate was downloaded and parsed
    check switch.autoTLSMgr.cert.isSome
    if switch.autoTLSMgr.cert.isNone:
      return

    let certBefore = switch.autoTLSMgr.cert.get()

    # invalidate certificate
    switch.autoTLSMgr.certExpiry = Opt.some(Moment.now - 2.hours)
    # cert was invalidated correctly
    check switch.autoTLSMgr.certExpiry.get < Moment.now

    # wait for cert to be renewed
    await switch.autoTLSMgr.certReady.wait()

    # certificate was indeed renewed
    check switch.autoTLSMgr.cert.isSome
    let certAfter = switch.autoTLSMgr.cert.get()
    check certBefore != certAfter
    check switch.autoTLSMgr.certExpiry.isSome
    # cert is valid
    check switch.autoTLSMgr.certExpiry.get > Moment.now
    await switch.stop()
