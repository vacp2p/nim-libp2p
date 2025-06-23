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
  ../libp2p/
    [
      stream/connection,
      upgrademngrs/upgrade,
      autotls/acme/api,
      autotls/acme/client,
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
    let acmeApi = await ACMEApi.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
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
    check challenge.finalize.len() > 0
    check challenge.order.len() > 0

    check challenge.dns01.url.len() > 0
    check challenge.dns01.`type` == ACMEChallengeType.dns01
    check challenge.dns01.status == ACMEChallengeStatus.pending
    check challenge.dns01.token.len() > 0

  asyncTest "request challenge with ACMEClient":
    let acme = await ACMEClient.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
    defer:
      await acme.close()

    let challenge = await acme.getChallenge(@["some.dummy.domain.com"])

    check challenge.finalize.len() > 0
    check challenge.order.len() > 0
    check challenge.dns01.url.len() > 0
    check challenge.dns01.`type` == ACMEChallengeType.dns01
    check challenge.dns01.status == ACMEChallengeStatus.pending
    check challenge.dns01.token.len() > 0
