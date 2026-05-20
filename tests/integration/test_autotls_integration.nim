# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

when defined(linux) and defined(amd64) and defined(libp2p_autotls_support):
  {.push raises: [].}

  import chronos, chronos/apps/http/httpclient
  import
    ../../libp2p/[
      stream/connection,
      upgrademngrs/upgrade,
      autotls/acme/api,
      autotls/acme/client,
      autotls/service,
      autotls/utils,
      multiaddress,
      utils/ipaddr,
      switch,
      nameresolving/dnsresolver,
      wire,
    ]
  import ../tools/[unittest, crypto, switch_builder]

  template assertChallenge(challenge: ACMEChallengeResponseWrapper): auto =
    check:
      challenge.finalize.len > 0
      challenge.order.len > 0
      challenge.dns01.url.len > 0
      challenge.dns01.`type` == ACMEChallengeType.DNS01
      challenge.dns01.status == ACMEChallengeStatus.PENDING
      challenge.dns01.token.len > 0

  suite "AutoTLS Integration":
    asyncTeardown:
      checkTrackers()

    asyncTest "request challenge without ACMEClient (ACMEApi only)":
      let key = KeyPair.random(PKScheme.RSA, rng()).get()
      let acmeApi = ACMEApi.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
      defer:
        await acmeApi.close()

      let challenge =
        try:
          let registerResponse = await acmeApi.requestRegister(key)
          # account was registered (kid set)
          check registerResponse.kid != ""
          if registerResponse.kid == "":
            raiseAssert "unable to register acme account"

          # challenge requested
          await acmeApi.requestChallenge(
            @["some.dummy.domain.com"], key, registerResponse.kid
          )
        except ACMENetworkError:
          skip()
          return

      assertChallenge(challenge)

    asyncTest "request challenge with ACMEClient":
      let acme = ACMEClient.new(
        rng = rng(), api = ACMEApi.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
      )
      defer:
        await acme.close()

      let challenge =
        try:
          await acme.getChallenge(@["some.dummy.domain.com"])
        except ACMENetworkError:
          skip()
          return

      assertChallenge(challenge)

    asyncTest "AutotlsService correctly downloads challenges":
      if not hasPublicIPAddress():
        skip()
        return

      let switch = makeStandardSwitchBuilder(
          MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
        )
        .withAutotls(
          config = AutotlsConfig.new(
            acmeServerURL = parseUri(LetsEncryptURLStaging), renewCheckTime = 1.seconds
          )
        )
        .build()

      await switch.start()
      defer:
        await switch.stop()

      # find autotls service in switch
      var autotls: AutotlsService = nil
      for service in switch.services:
        if service of AutotlsService:
          autotls = AutotlsService(service)
          break

      if autotls.isNil():
        raiseAssert "No Autotls service in switch"

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
      let certBefore = autotls.cert.valueOr:
        raiseAssert "certificate not found"

      # invalidate certificate
      let invalidCert =
        AutotlsCert.new(certBefore.cert, certBefore.privkey, Moment.now - 2.hours)
      autotls.cert = Opt.some(invalidCert)

      # wait for cert to be renewed
      await autotls.certReady.wait()

      # certificate was indeed renewed
      let certAfter = autotls.cert.valueOr:
        raiseAssert "certificate not found"

      check certBefore.cert != certAfter.cert

      # cert is valid
      check certAfter.expiry > Moment.now
