# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import sequtils, json, uri, chronos, chronos/apps/http/httpclient
import
  ../../../libp2p/
    [stream/connection, upgrademngrs/upgrade, autotls/acme/client, crypto/rsa, wire]
import ../../tools/[unittest, crypto]
import ../../stubs/acme_api_stub

suite "AutoTLS ACME API":
  const WildcardDomain = "*.example.libp2p.direct"

  # RSA generation dominates the runtime of every test here, so one pair for all.
  let
    key = RsaPrivateKey.random(rng()).get()
    certKey = RsaPrivateKey.random(rng()).get()

  var api {.threadvar.}: ACMEApiStub

  proc queueRegister() =
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{"status": "valid"},
        headers: HttpTable.init(@[("location", AccountURL)]),
      )
    )

  proc queueOrder(status: string, authorizations: JsonNode) =
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{
          "status": status, "authorizations": authorizations, "finalize": FinalizeURL
        },
        headers: HttpTable.init(@[("location", OrderURL)]),
      )
    )

  proc queueChallenges(challenges: JsonNode) =
    api.mockedResponses.add(
      HTTPResponse(body: %*{"challenges": challenges}, headers: HttpTable.init())
    )

  asyncTeardown:
    await api.close()
    checkTrackers()

  asyncSetup:
    api = ACMEApiStub.new()

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
        body: %*{
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
    check challengeResponse.status == ACMEOrderStatus.PENDING
    check challengeResponse.authorizations ==
      ["http://example.com/expected-authorizations-url"]
    check challengeResponse.finalize == "http://example.com/expected-finalize-url"
    check challengeResponse.order == "http://example.com/expected-order-url"

    # reset mocked obj for second request
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{
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
      it.`type` == ACMEChallengeType.DNS01
    )[0]
    check dns01.url == "http://example.com/expected-dns01-url"
    check dns01.`type` == ACMEChallengeType.DNS01
    check dns01.token == ACMEChallengeToken("expected-dns01-token")
    check dns01.status == ACMEChallengeStatus.PENDING

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
      certKey,
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
      certKey,
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
    let finalized = await api.certificateFinalized(
      "some-domain",
      parseUri("http://example.com/some-finalize-url"),
      parseUri("http://example.com/some-order-url"),
      certKey,
      key,
      "kid",
    )
    check finalized == false

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

    # clear leftover invalid responses so the mixed response is next in queue
    api.mockedResponses = @[]
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{
          "identifier": {"type": "dns", "value": "example.com"},
          "status": "pending",
          "challenges": [
            {
              "type": "dns-persist-01",
              "url": "http://example.com/unknown-challenge",
              "status": "pending",
              "token": "unknown-token",
            },
            {
              "type": "dns-01",
              "url": "http://example.com/recognized-challenge",
              "status": "pending",
              "token": "recognized-token",
            },
          ],
        },
        headers: HttpTable.init(),
      )
    )

    let mixedAuthResp = await api.requestAuthorizations(@["auth-3"], key, "kid")
    check mixedAuthResp.challenges.len == 2

    # replenish invalid responses for the remaining expect(ACMEError) blocks
    for _ in 0 .. 5:
      api.mockedResponses.add(
        HTTPResponse(
          body: %*{"inexistent field": "invalid value"}, headers: HttpTable.init()
        )
      )

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
        "some-domain",
        parseUri("http://example.com/some-finalize-url"),
        certKey,
        key,
        "kid",
      )

    expect(ACMEError):
      discard await api.requestGetOrder(parseUri("http://example.com/some-order-url"))

  asyncTest "the directory is fetched once and cached":
    # The cache is only observable on a stub that was not handed a directory.
    await api.close()
    api = ACMEApiStub.new(directory = Opt.none(ACMEDirectory))
    api.mockedResponses.add(
      HTTPResponse(
        body: %*{
          "newNonce": StubDirectory.newNonce,
          "newOrder": StubDirectory.newOrder,
          "newAccount": StubDirectory.newAccount,
        },
        headers: HttpTable.init(),
      )
    )
    for _ in 0 ..< 2:
      api.mockedResponses.add(
        HTTPResponse(
          body: %*{}, headers: HttpTable.init(@[("Replay-Nonce", "some-nonce")])
        )
      )

    # The stub overrides requestNonce, so call the real one that consults the directory.
    discard await procCall requestNonce(ACMEApi(api))
    discard await procCall requestNonce(ACMEApi(api))

    check api.requestedUris ==
      @[
        parseUri(LetsEncryptURL & "/directory"),
        parseUri(StubDirectory.newNonce),
        parseUri(StubDirectory.newNonce),
      ]

  asyncTest "the replay nonce is read from the response header":
    const nonce = "some-replay-nonce"
    api.mockedResponses.add(
      HTTPResponse(body: %*{}, headers: HttpTable.init(@[("Replay-Nonce", nonce)]))
    )

    check (await procCall requestNonce(ACMEApi(api))) == nonce

  asyncTest "the register request is signed with a jwk":
    queueRegister()

    discard await api.requestRegister(key)

    check api.protectedHeader(0).hasKey("jwk")

  asyncTest "the register request agrees to the terms of service":
    queueRegister()

    discard await api.requestRegister(key)

    check api.signedPayload(0)["termsOfServiceAgreed"].getBool

  asyncTest "an order request is signed with the account kid":
    queueOrder("pending", %*[AuthorizationsURL])

    discard await api.requestNewOrder(@[WildcardDomain], key, AccountURL)

    check api.protectedHeader(0)["kid"].getStr == AccountURL

  asyncTest "the order payload names the domain as a dns identifier":
    queueOrder("pending", %*[AuthorizationsURL])

    discard await api.requestNewOrder(@[WildcardDomain], key, AccountURL)

    check api.signedPayload(0)["identifiers"] ==
      %*[{"type": "dns", "value": WildcardDomain}]

  asyncTest "successive signed requests carry different nonces":
    queueRegister()
    queueOrder("pending", %*[AuthorizationsURL])

    discard await api.requestRegister(key)
    discard await api.requestNewOrder(@[WildcardDomain], key, AccountURL)

    check api.protectedHeader(0)["nonce"] != api.protectedHeader(1)["nonce"]

  asyncTest "an order with no authorizations is refused":
    queueOrder("pending", %*[])

    expect(ACMEError):
      discard await api.requestNewOrder(@[WildcardDomain], key, AccountURL)

  asyncTest "an order that is neither pending nor ready is refused":
    queueOrder("invalid", %*[AuthorizationsURL])
    # The authorization is in place, so only the status can stop the call.
    queueChallenges(
      %*[{"type": "dns-01", "url": ChallengeURL, "status": "pending", "token": "t"}]
    )

    expect(ACMEError):
      discard await api.requestChallenge(@[WildcardDomain], key, AccountURL)

  asyncTest "an authorization offering no dns-01 challenge is refused":
    queueOrder("pending", %*[AuthorizationsURL])
    queueChallenges(
      %*[
        {"type": "http-01", "url": ChallengeURL, "status": "pending", "token": "t"},
        {"type": "tls-alpn-01", "url": ChallengeURL, "status": "pending", "token": "t"},
      ]
    )

    expect(ACMEError):
      discard await api.requestChallenge(@[WildcardDomain], key, AccountURL)

  asyncTest "an unrecognized challenge type does not discard the dns-01 beside it":
    queueChallenges(
      %*[
        {
          "type": "dns-account-01",
          "url": "https://acme.example/chal/2",
          "status": "pending",
          "token": "t",
        },
        {"type": "dns-01", "url": ChallengeURL, "status": "pending", "token": "t"},
      ]
    )

    let authorizations =
      await api.requestAuthorizations(@[AuthorizationsURL], key, AccountURL)

    check authorizations.challenges.len == 1
    check authorizations.challenges[0].`type` == ACMEChallengeType.DNS01
    check authorizations.challenges[0].url == ChallengeURL

suite "AutoTLS ACME Client":
  # RSA generation dominates the runtime of every test here, so one pair for all.
  let
    key = RsaPrivateKey.random(rng()).get()
    certKey = RsaPrivateKey.random(rng()).get()

  var acmeApi {.threadvar.}: ACMEApiStub
  var acme {.threadvar.}: ACMEClient

  asyncSetup:
    acmeApi = ACMEApiStub.new()

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

    acme = ACMEClient.new(rng = rng(), api = ACMEApi(acmeApi), key = Opt.some(key))
    let kid = await acme.getOrInitKid()
    check kid == "some-expected-kid"

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
    acme = ACMEClient.new(rng = rng(), api = ACMEApi(acmeApi), key = Opt.some(key))
    let kid = await acme.getOrInitKid()
    check kid == "some-expected-kid"

    let challenge = ACMEChallengeDns01Response(
      finalize: "https://finalize.com",
      order: "https://order.com",
      dns01: ACMEChallenge(
        url: "https://some.domain",
        `type`: ACMEChallengeType.DNS01,
        status: ACMEChallengeStatus.VALID,
        token: ACMEChallengeToken("some-token"),
      ),
    )
    expect(ACMEError):
      discard await acme.getCertificate(api.Domain("some.domain"), certKey, challenge)
