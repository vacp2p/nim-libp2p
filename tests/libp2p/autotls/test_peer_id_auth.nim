# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}
{.push raises: [].}

import chronos, chronos/apps/http/httpclient, uri, base64, times
import
  ../../../libp2p/
    [stream/connection, upgrademngrs/upgrade, peeridauth/client, wire, crypto/crypto]
import ../../tools/[unittest, crypto]
import ../../stubs/peer_id_auth_client_stub

suite "PeerID Auth Client":
  const ExampleURL = "https://example.com/some/uri"

  # keys from the peer-id-auth spec's handshake examples
  let
    specServerKey = PrivateKey
      .init(
        "0801124001010101010101010101010101010101010101010101010101010101010101018a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
      )
      .get()
    specClientKey = PrivateKey
      .init(
        "0801124002020202020202020202020202020202020202020202020202020202020202028139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b394"
      )
      .get()

  # RSA generation dominates the runtime of every test here, so one key for all.
  let peerInfo =
    try:
      PeerInfo.new(PrivateKey.random(PKScheme.RSA, rng()).get())
    except LPError as exc:
      raiseAssert "could not build the client PeerInfo: " & exc.msg

  var client {.threadvar.}: PeerIDAuthClientStub

  asyncTeardown:
    await client.close()
    checkTrackers()

  asyncSetup:
    client = PeerIDAuthClientStub.new()

  proc requestWithExpires(
      expires: string
  ): Future[PeerIDAuthAuthorizationResponse] {.
      async: (raises: [PeerIDAuthError, CancelledError])
  .} =
    client.authenticationInfo = Opt.some(
      PeerIDAuthPrefix & " sig=\"somesig\", bearer=\"somebearer\", expires=\"" & expires &
        "\""
    )
    await client.requestAuthorization(
      peerInfo,
      parseUri(ExampleURL),
      "some-challenge-client",
      "some-challenge-server",
      specServerKey.getPublicKey().get(),
      "some-opaque",
      "some-payload",
    )

  asyncTest "request authentication":
    let serverPubkey = specServerKey.getPublicKey().get()
    let b64serverPubkey = serverPubkey.pubkeyBytes().encode(safe = true)
    client.wwwAuthenticate = Opt.some(
      PeerIDAuthPrefix & " challenge-client=\"somechallengeclient\", public-key=\"" &
        b64serverPubkey & "\", opaque=\"someopaque\""
    )

    let authenticationResponse =
      await client.requestAuthentication(parseUri(ExampleURL))

    check authenticationResponse.challengeClient ==
      PeerIDAuthChallenge("somechallengeclient")
    check authenticationResponse.opaque == PeerIDAuthOpaque("someopaque")
    check authenticationResponse.serverPubkey == serverPubkey

  asyncTest "request authorization":
    let sig = PeerIDAuthSignature("somesig")
    let bearer = BearerToken(token: "somebearer", expires: Opt.none(DateTime))
    client.authenticationInfo = Opt.some(
      PeerIDAuthPrefix & " sig=\"" & sig & "\", bearer=\"" & bearer.token & "\""
    )

    let uri = parseUri(ExampleURL)
    let serverPubkey = specServerKey.getPublicKey().get()
    let authorizationResponse = await client.requestAuthorization(
      peerInfo, uri, "some-challenge-client", "some-challenge-server", serverPubkey,
      "some-opaque", "some-payload",
    )
    check authorizationResponse.bearer == bearer
    check authorizationResponse.sig == sig

  asyncTest "client signature matches the peer-id-auth spec vector":
    discard await client.requestAuthorization(
      PeerInfo.new(specClientKey),
      parseUri(ExampleURL),
      "ERERERERERERERERERERERERERERERERERERERERERE=",
      "MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMz",
      specServerKey.getPublicKey().get(),
      "someopaque",
      "somepayload",
    )

    # expected signature from peer-id-auth spec
    check client.authField(0, "sig") ==
      "OrwJPO4buHKJdKXP2av8PFwv3XF_-m5MqndskeVV5UzufYzBCTm7RBaFnBS1sEhuQHZSZPh9RJgN5NmLzrUrBQ=="

  asyncTest "each handshake draws a fresh challenge-server":
    let uri = parseUri(ExampleURL)
    discard await client.send(uri, peerInfo, "somepayload")
    discard await client.send(uri, peerInfo, "somepayload")

    check client.authField(0, "challenge-server") !=
      client.authField(1, "challenge-server")

  asyncTest "server signature over another challenge is rejected":
    client.challengeServer = Opt.some("someotherchallenge")

    expect PeerIDAuthError:
      discard await client.send(parseUri(ExampleURL), peerInfo, "somepayload")

  asyncTest "bearer expiry is parsed in local time":
    # TODO: vacp2p/nim-libp2p#2975
    let expires =
      (await requestWithExpires("2026-08-21T12:00:00.000Z")).bearer.expires.get()

    check expires.timezone == local()
    check expires.format("yyyy-MM-dd'T'HH:mm:ss") == "2026-08-21T12:00:00"

  asyncTest "bearer expiry reads a nanosecond fraction as milliseconds":
    # TODO: vacp2p/nim-libp2p#2975
    let expires =
      (await requestWithExpires("2026-08-21T11:36:41.621940726Z")).bearer.expires.get()

    check expires - dateTime(2026, mAug, 21, 11, 36, 41, zone = local()) ==
      initDuration(milliseconds = 621_940_726)

  asyncTest "bearer expiry without a fractional second is dropped":
    # TODO: vacp2p/nim-libp2p#2975
    check (await requestWithExpires("2026-08-21T12:00:00Z")).bearer.expires.isNone()

  asyncTest "bearer expiry without a zone raises IndexDefect":
    # TODO: vacp2p/nim-libp2p#2975
    expect IndexDefect:
      discard await requestWithExpires("2026-08-21T12:00:00")

  asyncTest "a url the session cannot turn into an address is an http error":
    # The stub overrides post, so this drives the real one.
    let realClient = PeerIDAuthClient.new(rng())
    defer:
      await realClient.close()

    expect(HttpError):
      discard await realClient.post(parseUri(""), "somepayload", "someauthheader")

  test "checkSignature successful":
    # example from peer-id-auth spec
    let serverPublicKey = specServerKey.getPublicKey().get()
    let challenge = "ERERERERERERERERERERERERERERERERERERERERERE="
    let hostname = "example.com"
    let sig =
      "UA88qZbLUzmAxrD9KECbDCgSKAUBAvBHrOCF2X0uPLR1uUCF7qGfLPc7dw3Olo-LaFCDpk5sXN7TkLWPVvuXAA=="
    let clientPublicKey = specClientKey.getPublicKey().get()
    check checkSignature(sig, serverPublicKey, challenge, clientPublicKey, hostname)

  test "checkSignature failed":
    # example from peer-id-auth spec (but with sig altered)
    let serverPublicKey = specServerKey.getPublicKey().get()
    let challenge = "ERERERERERERERERERERERERERERERERERERERERERE="
    let hostname = "example.com"
    let sig =
      "ZZZZZZZZZZZZZZZ9KECbDCgSKAUBAvBHrOCF2X0uPLR1uUCF7qGfLPc7dw3Olo-LaFCDpk5sXN7TkLWPVvuXAA=="
    let clientPublicKey = specClientKey.getPublicKey().get()
    check checkSignature(sig, serverPublicKey, challenge, clientPublicKey, hostname) ==
      false
