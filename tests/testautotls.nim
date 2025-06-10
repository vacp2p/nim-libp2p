{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import sequtils, json
import chronos, chronos/apps/http/httpclient
import ../libp2p/[stream/connection, upgrademngrs/upgrade, autotls/acme/mockapi, wire]

import ./helpers

suite "AutoTLS ACME Client":
  var api {.threadvar.}: MockACMEApi
  var key {.threadvar.}: KeyPair

  asyncTeardown:
    await api.close()
    checkTrackers()

  asyncSetup:
    api = await MockACMEApi.new()
    api.mockedHeaders = HttpTable.init()
    key = KeyPair.random(PKScheme.RSA, newRng()[]).get()

  asyncTest "register to acme server":
    api.mockedBody = %*{"status": "valid"}
    api.mockedHeaders.add("location", "some-expected-kid")

    let registerResponse = await api.requestRegister(key)
    check registerResponse.kid == "some-expected-kid"

  asyncTest "request challenge for a domain":
    api.mockedBody =
      %*{
        "status": "pending",
        "authorizations": ["expected-authorizations-url"],
        "finalize": "expected-finalize-url",
      }
    api.mockedHeaders.set("location", "expected-order-url")

    let challengeResponse =
      await api.requestNewOrder(@["some.dummy.domain.com"], key, "kid")
    check challengeResponse.status == ACMEChallengeStatus.pending
    check challengeResponse.authorizations == ["expected-authorizations-url"]
    check challengeResponse.finalize == "expected-finalize-url"
    check challengeResponse.orderURL == "expected-order-url"

    # reset mocked obj for second request
    api.mockedBody =
      %*{
        "challenges": [
          {
            "url": "expected-dns01-url",
            "type": "dns-01",
            "status": "pending",
            "token": "expected-dns01-token",
          }
        ]
      }

    let authorizationsResponse =
      await api.requestAuthorizations(challengeResponse.authorizations, key, "kid")
    check authorizationsResponse.challenges.len > 0

    let dns01 = authorizationsResponse.challenges.filterIt(it.`type` == "dns-01")[0]
    check dns01.url == "expected-dns01-url"
    check dns01.`type` == "dns-01"
    check dns01.token == "expected-dns01-token"
    check dns01.status == ACMEChallengeStatus.pending

  asyncTest "register with unsupported keys":
    let unsupportedSchemes = [PKScheme.Ed25519, PKScheme.Secp256k1, PKScheme.ECDSA]
    for scheme in unsupportedSchemes:
      let unsupportedKey = KeyPair.random(scheme, newRng()[]).get()
      expect(ACMEError):
        discard await api.requestRegister(unsupportedKey)

  asyncTest "request challenge with invalid kid":
    expect(ACMEError):
      discard await api.requestChallenge(@["domain.com"], key, "invalid_kid_here")

  asyncTest "challenge completed successful":
    api.mockedBody = %*{"checkURL": "some-check-url"}
    discard await api.requestCompleted("some-chal-url", key, "kid")

    api.mockedBody = %*{"status": "valid"}
    api.mockedHeaders.add("Retry-After", "1")
    let completed = await api.checkChallengeCompleted("some-chal-url", key, "kid")
    check completed == true

  asyncTest "challenge completed max retries reached":
    api.mockedBody = %*{"checkURL": "some-check-url"}
    discard await api.requestCompleted("some-chal-url", key, "kid")

    api.mockedBody = %*{"status": "pending"}
    api.mockedHeaders.add("Retry-After", "1")
    let completed =
      await api.checkChallengeCompleted("some-chal-url", key, "kid", retries = 1)
    check completed == false

  asyncTest "challenge completed invalid":
    api.mockedBody = %*{"checkURL": "some-check-url"}
    discard await api.requestCompleted("some-chal-url", key, "kid")

    api.mockedBody = %*{"status": "invalid"}
    api.mockedHeaders.add("Retry-After", "1")
    expect(ACMEError):
      discard await api.checkChallengeCompleted("some-chal-url", key, "kid")

  asyncTest "finalize certificate successful":
    api.mockedBody = %*{"status": "valid"}
    api.mockedHeaders.add("Retry-After", "1")
    let finalized = await api.certificateFinalized(
      "some-domain", "some-finalize-url", "some-order-url", key, "kid"
    )
    check finalized == true

  asyncTest "finalize certificate max retries reached":
    api.mockedBody = %*{"status": "processing"}
    api.mockedHeaders.add("Retry-After", "1")
    let finalized = await api.certificateFinalized(
      "some-domain", "some-finalize-url", "some-order-url", key, "kid", retries = 1
    )
    check finalized == false

  asyncTest "finalize certificate invalid":
    api.mockedBody = %*{"status": "invalid"}
    api.mockedHeaders.add("Retry-After", "1")
    expect(ACMEError):
      discard await api.certificateFinalized(
        "some-domain", "some-finalize-url", "some-order-url", key, "kid"
      )

  asyncTest "expect error on invalid JSON response":
    api.mockedBody = %*{"inexistent field": "invalid value"}

    expect(ACMEError):
      # avoid calling overloaded mock method requestNonce here since we want to test the actual thing
      discard await procCall requestNonce(ACMEApi(api))

    expect(ACMEError):
      discard await api.requestRegister(key)

    expect(ACMEError):
      discard await api.requestNewOrder(@["some-domain"], key, "kid")

    expect(ACMEError):
      discard await api.requestAuthorizations(@["auth-1", "auth-2"], key, "kid")

    expect(ACMEError):
      discard await api.requestChallenge(@["domain-1", "domain-2"], key, "kid")

    expect(ACMEError):
      discard await api.requestCheck(
        "some-check-url", ACMECheckKind.ACMEOrderCheck, key, "kid"
      )

    expect(ACMEError):
      discard await api.requestCheck(
        "some-check-url", ACMECheckKind.ACMEChallengeCheck, key, "kid"
      )

    expect(ACMEError):
      discard await api.requestCompleted("some-chal-url", key, "kid")

    expect(ACMEError):
      discard await api.requestFinalize("some-domain", "some-finalize-url", key, "kid")

    expect(ACMEError):
      discard await api.requestGetOrder("some-order-url")
