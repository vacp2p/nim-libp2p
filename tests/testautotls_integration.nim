# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos
import chronos/apps/http/httpclient
import
  ../libp2p/[
    stream/connection,
    upgrademngrs/upgrade,
    autotls/acme/api,
    autotls/acme/client,
    autotls/service,
    autotls/utils,
    multiaddress,
    switch,
    builders,
    nameresolving/dnsresolver,
    wire,
  ]

import ./helpers

when defined(linux) and defined(amd64):
  {.used.}

  suite "AutoTLS Integration":
    asyncTeardown:
      checkTrackers()

    asyncTest "request challenge without ACMEClient (ACMEApi only)":
      let key = KeyPair.random(PKScheme.RSA, newRng()[]).get()
      let acmeApi = ACMEApi.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
      defer:
        await acmeApi.close()
      let registerResponse = await acmeApi.requestRegister(key)
      # account was registered (kid set)
      check registerResponse.kid != ""
      if registerResponse.kid == "":
        raiseAssert "unable to register acme account"

      # challenge requested
      let challenge = await acmeApi.requestChallenge(
        @["some.dummy.domain.com"], key, registerResponse.kid
      )
      check challenge.finalize.len > 0
      check challenge.order.len > 0

      check challenge.dns01.url.len > 0
      check challenge.dns01.`type` == ACMEChallengeType.DNS01
      check challenge.dns01.status == ACMEChallengeStatus.PENDING
      check challenge.dns01.token.len > 0

    asyncTest "request challenge with ACMEClient":
      let acme = ACMEClient.new(
        api = ACMEApi.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
      )
      defer:
        await acme.close()

      let challenge = await acme.getChallenge(@["some.dummy.domain.com"])

      check:
        challenge.finalize.len > 0
        challenge.order.len > 0
        challenge.dns01.url.len > 0
        challenge.dns01.`type` == ACMEChallengeType.DNS01
        challenge.dns01.status == ACMEChallengeStatus.PENDING
        challenge.dns01.token.len > 0

    asyncTest "AutotlsService correctly downloads challenges":
      let ip =
        try:
          getPublicIPAddress()
        except:
          skip() # host doesn't have public IPv4 address
          return

      let switch = SwitchBuilder
        .new()
        .withRng(newRng())
        .withAddress(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
        .withTcpTransport()
        .withAutotls(
          config = AutotlsConfig.new(
            acmeServerURL = parseUri(LetsEncryptURLStaging), renewCheckTime = 1.seconds
          )
        )
        .withYamux()
        .withNoise()
        .build()

      await switch.start()
      defer:
        await switch.stop()

      # find autotls in list of services
      var autotls: AutotlsService = nil
      for service in switch.services:
        try:
          autotls = AutotlsService(service)
          break
        except:
          continue

      if autotls.isNil():
        raiseAssert "autotls service not found in switch"

      # wait for cert to be ready
      await autotls.certReady.wait()
      # clear since we'll use it again for renewal
      autotls.certReady.clear()

      let dnsResolver = DnsResolver.new(DefaultDnsServers)
      let base36PeerId = encodePeerId(switch.peerInfo.peerId)
      let dnsTXTRecord = (
        await dnsResolver.resolveTxt(
          "_acme-challenge." & base36PeerId & "." & AutoTLSDNSServer
        )
      )[0]

      # check if DNS TXT record is set
      check dnsTXTRecord.len > 0

      # certificate was downloaded and parsed
      let cert = autotls.cert.valueOr:
        raiseAssert "certificate not found"
      let certBefore = cert

      # invalidate certificate
      let invalidCert = AutotlsCert.new(cert.cert, Moment.now - 2.hours)
      autotls.cert = Opt.some(invalidCert)

      # wait for cert to be renewed
      await autotls.certReady.wait()

      # certificate was indeed renewed
      let certAfter = autotls.cert.valueOr:
        raiseAssert "certificate not found"

      check certBefore != certAfter

      # cert is valid
      check certAfter.expiry > Moment.now
