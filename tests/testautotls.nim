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

import sequtils, json, uri
import chronos, chronos/apps/http/httpclient
import
  ../libp2p/[
    stream/connection,
    upgrademngrs/upgrade,
    autotls/acme/mockapi,
    autotls/acme/client,
    wire,
  ]

import ./helpers

suite "AutoTLS ACME API":
  var api {.threadvar.}: MockACMEApi
  var key {.threadvar.}: KeyPair

  asyncTeardown:
    await api.close()
    checkTrackers()

  asyncSetup:
    api = await MockACMEApi.new()
    key = KeyPair.random(PKScheme.RSA, newRng()[]).get()

  asyncTest "register to acme server":
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "valid"},
        headers: HttpTable.init(@[("location", "some-expected-kid")]),
      )
    )

    let registerResponse = await api.requestRegister(key)
    check registerResponse.kid == "some-expected-kid"

  asyncTest "request challenge for a domain":
    api.mockedResponses.add(
      HTTPResponse(
        body:
          %*{
            "status": "pending",
            "authorizations": ["http://example.com/expected-authorizations-url"],
            "finalize": "http://example.com/expected-finalize-url",
          },
        headers:
          HttpTable.init(@[("location", "http://example.com/expected-order-url")]),
      )
    )

    let challengeResponse =
      await api.requestNewOrder(@["some.dummy.domain.com"], key, "kid")
    check challengeResponse.status == ACMEOrderStatus.pending
    check challengeResponse.authorizations ==
      ["http://example.com/expected-authorizations-url"]
    check challengeResponse.finalize == "http://example.com/expected-finalize-url"
    check challengeResponse.order == "http://example.com/expected-order-url"

    # reset mocked obj for second request
    api.mockedResponses.add(
      HTTPResponse(
        body:
          %*{
            "challenges": [
              {
                "url": "http://example.com/expected-dns01-url",
                "type": "dns-01",
                "status": "pending",
                "token": "expected-dns01-token",
              }
            ]
          },
        headers:
          HttpTable.init(@[("location", "http://example.com/expected-order-url")]),
      )
    )

    let authorizationsResponse =
      await api.requestAuthorizations(challengeResponse.authorizations, key, "kid")
    check authorizationsResponse.challenges.len > 0

    let dns01 = authorizationsResponse.challenges.filterIt(
      it.`type` == ACMEChallengeType.dns01
    )[0]
    check dns01.url == "http://example.com/expected-dns01-url"
    check dns01.`type` == ACMEChallengeType.dns01
    check dns01.token == ACMEChallengeToken("expected-dns01-token")
    check dns01.status == ACMEChallengeStatus.pending

  asyncTest "register with unsupported keys":
    let unsupportedSchemes = [PKScheme.Ed25519, PKScheme.Secp256k1, PKScheme.ECDSA]
    for scheme in unsupportedSchemes:
      let unsupportedKey = KeyPair.random(scheme, newRng()[]).get()
      expect(ACMEError):
        discard await api.requestRegister(unsupportedKey)

  asyncTest "challenge completed successful":
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"url": "http://example.com/some-check-url"}, headers: HttpTable.init()
      )
    )
    discard await api.sendChallengeCompleted(
      parseUri("http://example.com/some-chal-url"), key, "kid"
    )

    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "valid"}, headers: HttpTable.init(@[("Retry-After", "0")])
      )
    )
    let completed = await api.checkChallengeCompleted(
      parseUri("http://example.com/some-chal-url"), key, "kid"
    )
    check completed == true

  asyncTest "challenge completed max retries reached":
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"url": "http://example.com/some-check-url"}, headers: HttpTable.init()
      )
    )
    discard await api.sendChallengeCompleted(
      parseUri("http://example.com/some-chal-url"), key, "kid"
    )

    # add this mocked response a few times since checkChallengeCompleted might get more than once
    for _ in 0 .. 5:
      api.mockedResponses.add(
        HTTPResponse(
          body: %*{"status": "pending"},
          headers: HttpTable.init(@[("Retry-After", "0")]),
        )
      )
    let completed = await api.checkChallengeCompleted(
      parseUri("http://example.com/some-chal-url"), key, "kid", retries = 1
    )
    check completed == false

  asyncTest "challenge completed invalid":
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"url": "http://example.com/some-check-url"}, headers: HttpTable.init()
      )
    )
    discard await api.sendChallengeCompleted(
      parseUri("http://example.com/some-chal-url"), key, "kid"
    )

    # add this mocked response a few times since checkChallengeCompleted might get more than once
    for _ in 0 .. 5:
      api.mockedResponses.add(
        HTTPResponse(
          body: %*{"status": "invalid"},
          headers: HttpTable.init(@[("Retry-After", "0")]),
        )
      )

    expect(ACMEError):
      discard await api.checkChallengeCompleted(
        parseUri("http://example.com/some-chal-url"), key, "kid"
      )

  asyncTest "finalize certificate successful":
    # first status is processing, then valid
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "processing"},
        headers: HttpTable.init(@[("Retry-After", "0")]),
      )
    )
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "valid"}, headers: HttpTable.init(@[("Retry-After", "0")])
      )
    )
    let finalized = await api.certificateFinalized(
      "some-domain",
      parseUri("http://example.com/some-finalize-url"),
      parseUri("http://example.com/some-order-url"),
      key,
      "kid",
    )
    check finalized == true

  asyncTest "finalize certificate max retries reached":
    # add this mocked response a few times since checkCertFinalized might get more than once
    for _ in 0 .. 5:
      api.mockedResponses.add(
        HTTPResponse(
          body: %*{"status": "processing"},
          headers: HttpTable.init(@[("Retry-After", "0")]),
        )
      )
    let finalized = await api.certificateFinalized(
      "some-domain",
      parseUri("http://example.com/some-finalize-url"),
      parseUri("http://example.com/some-order-url"),
      key,
      "kid",
      retries = 1,
    )
    check finalized == false

  asyncTest "finalize certificate invalid":
    # first request is processing, then invalid
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "processing"},
        headers: HttpTable.init(@[("Retry-After", "0")]),
      )
    )
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "invalid"}, headers: HttpTable.init(@[("Retry-After", "0")])
      )
    )
    expect(ACMEError):
      discard await api.certificateFinalized(
        "some-domain",
        parseUri("http://example.com/some-finalize-url"),
        parseUri("http://example.com/some-order-url"),
        key,
        "kid",
      )

  asyncTest "expect error on invalid JSON response":
    # add a couple invalid responses as they get popped by every get or post call
    for _ in 0 .. 20:
      api.mockedResponses.add(
        HTTPResponse(
          body: %*{"inexistent field": "invalid value"}, headers: HttpTable.init()
        )
      )

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
        parseUri("http://example.com/some-check-url"),
        ACMECheckKind.ACMEOrderCheck,
        key,
        "kid",
      )

    expect(ACMEError):
      discard await api.requestCheck(
        parseUri("http://example.com/some-check-url"),
        ACMECheckKind.ACMEChallengeCheck,
        key,
        "kid",
      )

    expect(ACMEError):
      discard await api.sendChallengeCompleted(
        parseUri("http://example.com/some-chal-url"), key, "kid"
      )

    expect(ACMEError):
      discard await api.requestFinalize(
        "some-domain", parseUri("http://example.com/some-finalize-url"), key, "kid"
      )

    expect(ACMEError):
      discard await api.requestGetOrder(parseUri("http://example.com/some-order-url"))

suite "AutoTLS ACME Client":
  var acmeApi {.threadvar.}: MockACMEApi
  var acme {.threadvar.}: ACMEClient

  asyncSetup:
    acmeApi = await MockACMEApi.new()

  asyncTeardown:
    await acme.close()
    checkTrackers()

  asyncTest "client registers new account when instantiated":
    acmeApi.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "valid"},
        headers: HttpTable.init(@[("location", "some-expected-kid")]),
      )
    )

    acme = await ACMEClient.new(api = Opt.some(ACMEApi(acmeApi)))
    check acme.kid == "some-expected-kid"

  asyncTest "getCertificate succeeds on sendChallengeCompleted but fails on requestFinalize":
    # register successful
    acmeApi.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "valid"},
        headers: HttpTable.init(@[("location", "some-expected-kid")]),
      )
    )
    # request completed successful
    acmeApi.mockedResponses.add(
      HTTPResponse(
        body: %*{"url": "http://example.com/some-check-url"}, headers: HttpTable.init()
      )
    )
    # finalize is invalid
    # first request is processing, then invalid
    acmeApi.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "processing"},
        headers: HttpTable.init(@[("Retry-After", "0")]),
      )
    )
    acmeApi.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "invalid"}, headers: HttpTable.init(@[("Retry-After", "0")])
      )
    )
    acme = await ACMEClient.new(api = Opt.some(ACMEApi(acmeApi)))
    check acme.kid == "some-expected-kid"

    let challenge = ACMEChallengeResponseWrapper(
      finalize: "https://finalize.com",
      order: "https://order.com",
      dns01: ACMEChallenge(
        url: "https://some.domain",
        `type`: ACMEChallengeType.dns01,
        status: ACMEChallengeStatus.valid,
        token: ACMEChallengeToken("some-token"),
      ),
    )
    expect(ACMEError):
      discard await acme.getCertificate(api.Domain("some.domain"), challenge)
