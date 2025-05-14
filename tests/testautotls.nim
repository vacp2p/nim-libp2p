{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[strutils, sequtils, tables, strformat, net, json]
import chronos
import
  ../libp2p/[
    stream/connection,
    transports/tcptransport,
    upgrademngrs/upgrade,
    multiaddress,
    autotls/autotls,
    autotls/acme,
    autotls/utils,
    nameresolving/dnsresolver,
    wire,
  ]

import ./helpers

suite "AutoTLS":
  suite "ACME communication":
    var acc {.threadvar.}: ref ACMEAccount

    asyncSetup:
      let rng = newRng()
      let accountKey = KeyPair.random(PKScheme.RSA, rng[]).get()
      acc = await ACMEAccount.new(accountKey)

    asyncTest "test ACME account register":
      await acc.register()
      # account was registered (kid set)
      check acc.kid.isSome

    asyncTest "test ACME challange request":
      await acc.register()
      # challenge requested
      let (dns01Challenge, finalizeURL, orderURL) =
        await acc.requestChallenge(@["some.dummy.domain.com"])
      check dns01Challenge.isNil == false
      check finalizeURL.len > 0
      check orderURL.len > 0

    asyncTest "test notify ACME challenge complete":
      let hostPrimaryIP = getPrimaryIPAddr()
      if not isPublicIPv4(hostPrimaryIP):
        skip()
        return
      await acc.register()
      let (dns01Challenge, finalizeURL, orderURL) =
        await acc.requestChallenge(@["some.dummy.domain.com"])
      let chalURL = dns01Challenge["url"].getStr
      check (await acc.notifyChallengeCompleted(chalURL))

  suite "AutoTLS manager":
    var autotlsMgr {.threadvar.}: AutoTLSManager
    var peerInfo {.threadvar.}: PeerInfo

    asyncSetup:
      let rng = newRng()
      autotlsMgr = AutoTLSManager.new(rng)

      let seckey = PrivateKey.random(rng[]).tryGet()
      let peerId = PeerId.init(seckey).get()
      let multiAddresses = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
      peerInfo = PeerInfo.new(seckey, multiAddresses)

    asyncTest "test send challenge to AutoTLS broker":
      await autotlsMgr.start(peerInfo)

      # check if challenge was sent (bearer token from peer id auth was set)
      check autotlsMgr.bearerToken.isSome

    asyncTest "test DNS TXT record set":
      let hostPrimaryIP = getPrimaryIPAddr()
      if not isPublicIPv4(hostPrimaryIP):
        skip()
        return

      # check if DNS TXT record is set
      let dnsResolver = DnsResolver.new(
        @[
          initTAddress("1.1.1.1:53"),
          initTAddress("1.0.0.1:53"),
          initTAddress("[2606:4700:4700::1111]:53"),
        ]
      )
      let base36PeerId = encodePeerId(peerInfo.peerId)
      let baseDomain = fmt"{base36PeerId}.{AutoTLSDNSServer}"
      let acmeChalDomain = fmt"_acme-challenge.{baseDomain}"
      let txt = await dnsResolver.resolveTxt(acmeChalDomain)
      check txt.len > 0
      check txt[0] != "not set yet"

    asyncTest "test download certificate":
      let hostPrimaryIP = getPrimaryIPAddr()
      if not isPublicIPv4(hostPrimaryIP):
        skip()
        return
      await autotlsMgr.start(peerInfo)
      check autotlsMgr.cert.isSome
