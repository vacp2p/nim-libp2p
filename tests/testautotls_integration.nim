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
    autotls/manager,
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
    let acme = await ACMEClient.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
    defer:
      await acme.close()

    let challenge = await acme.getChallenge(@["some.dummy.domain.com"])

    check challenge.finalize.len > 0
    check challenge.order.len > 0
    check challenge.dns01.url.len > 0
    check challenge.dns01.`type` == ACMEChallengeType.DNS01
    check challenge.dns01.status == ACMEChallengeStatus.PENDING
    check challenge.dns01.token.len > 0

  asyncTest "AutoTLSManager correctly downloads challenges":
    let ip = checkedGetPrimaryIPAddr()
    if not ip.isIPv4() or not ip.isPublic():
      skip() # host doesn't have public IPv4 address
      return

    let switch = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddress(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
      .withTcpTransport()
      .withAutotls(acmeServerURL = parseUri(LetsEncryptURLStaging))
      .withYamux()
      .withNoise()
      .build()

    # this is to quickly renew cert for testing
    switch.autotls.renewCheckTime = 1.seconds

    await switch.start()
    defer:
      await switch.stop()

    # wait for cert to be ready
    await switch.autotls.certReady.wait()
    # clear since we'll use it again for renewal
    switch.autotls.certReady.clear()

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
    let cert = switch.autotls.cert.valueOr:
      raiseAssert "certificate not found"
    let certBefore = cert

    # invalidate certificate
    switch.autotls.certExpiry = Opt.some(Moment.now - 2.hours)

    # wait for cert to be renewed
    await switch.autotls.certReady.wait()

    # certificate was indeed renewed
    let certAfter = switch.autotls.cert.valueOr:
      raiseAssert "certificate not found"

    check certBefore != certAfter

    let certExpiry = switch.autotls.certExpiry.valueOr:
      raiseAssert "certificate expiry not found"

    # cert is valid
    check certExpiry > Moment.now
