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

import uri, base64, times
import chronos, chronos/apps/http/httpclient
import
  ../libp2p/
    [
      stream/connection,
      upgrademngrs/upgrade,
      peeridauth/mockclient,
      wire,
      crypto/crypto,
    ]

import ./helpers

suite "PeerID Auth Client":
  var client {.threadvar.}: MockPeerIDAuthClient
  var rng {.threadvar.}: ref HmacDrbgContext
  var peerInfo {.threadvar.}: PeerInfo

  asyncTeardown:
    await client.close()
    checkTrackers()

  asyncSetup:
    rng = newRng()
    client = MockPeerIDAuthClient.new(rng)
    client.mockedHeaders = HttpTable.init()
    peerInfo = PeerInfo.new(PrivateKey.random(PKScheme.RSA, rng[]).get())

  asyncTest "request authentication":
    let serverPrivateKey = PrivateKey.random(PKScheme.RSA, rng[]).get()
    let serverPubkey = serverPrivateKey.getPublicKey().get()
    let b64serverPubkey = serverPubkey.pubkeyBytes().encode(safe = true)
    client.mockedHeaders.add(
      "WWW-Authenticate",
      "libp2p-PeerID " & "challenge-client=\"somechallengeclient\", public-key=\"" &
        b64serverPubkey & "\", opaque=\"someopaque\"",
    )

    let authenticationResponse =
      await client.requestAuthentication(parseUri("https://example.com/some/uri"))

    check authenticationResponse.challengeClient ==
      PeerIDAuthChallenge("somechallengeclient")
    check authenticationResponse.opaque == PeerIDAuthOpaque("someopaque")
    check authenticationResponse.serverPubkey == serverPubkey

  asyncTest "request authorization":
    let sig = PeerIDAuthSignature("somesig")
    let bearer = BearerToken(token: "somebearer", expires: Opt.none(DateTime))
    client.mockedHeaders.add(
      "Authentication-Info",
      "libp2p-PeerID " & "sig=\"" & sig & "\", " & "bearer=\"" & bearer.token & "\"",
    )

    let uri = parseUri("https://example.com/some/uri")
    let serverPrivateKey = PrivateKey.random(PKScheme.RSA, rng[]).get()
    let serverPubkey = serverPrivateKey.getPublicKey().get()
    let authorizationResponse = await client.requestAuthorization(
      peerInfo, uri, "some-challenge-client", "some-challenge-server", serverPubkey,
      "some-opaque", "some-payload",
    )
    check authorizationResponse.bearer == bearer
    check authorizationResponse.sig == sig

  asyncTest "checkSignature successful":
    # example from peer-id-auth spec
    let serverPrivateKey = PrivateKey
      .init(
        "0801124001010101010101010101010101010101010101010101010101010101010101018a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
      )
      .get()

    let serverPublicKey = serverPrivateKey.getPublicKey().get()
    let challenge = "ERERERERERERERERERERERERERERERERERERERERERE="
    let hostname = "example.com"
    let sig =
      "UA88qZbLUzmAxrD9KECbDCgSKAUBAvBHrOCF2X0uPLR1uUCF7qGfLPc7dw3Olo-LaFCDpk5sXN7TkLWPVvuXAA=="
    let clientPublicKey = PublicKey
      .init("080112208139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b394")
      .get()
    check checkSignature(sig, serverPublicKey, challenge, clientPublicKey, hostname)

  asyncTest "checkSignature failed":
    # example from peer-id-auth spec (but with sig altered)
    let serverPrivateKey = PrivateKey
      .init(
        "0801124001010101010101010101010101010101010101010101010101010101010101018a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
      )
      .get()
    let serverPublicKey = serverPrivateKey.getPublicKey().get()
    let challenge = "ERERERERERERERERERERERERERERERERERERERERERE="
    let hostname = "example.com"
    let sig =
      "ZZZZZZZZZZZZZZZ9KECbDCgSKAUBAvBHrOCF2X0uPLR1uUCF7qGfLPc7dw3Olo-LaFCDpk5sXN7TkLWPVvuXAA=="
    let clientPublicKey = PublicKey
      .init("080112208139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b394")
      .get()
    check checkSignature(sig, serverPublicKey, challenge, clientPublicKey, hostname) ==
      false
