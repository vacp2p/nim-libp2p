# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

{.push raises: [].}

import base64, strutils, uri
import chronos, chronos/apps/http/httpclient, stew/byteutils
import ../../libp2p/[crypto/crypto, peeridauth/client, varint]
import ../tools/crypto

const
  ChallengeClient = "somechallengeclient"
  Opaque = "someopaque"

type PeerIDAuthClientStub* = ref object of PeerIDAuthClient
  ## Answers the PeerID Auth handshake as a server would, recording what was sent.
  serverKey: PrivateKey
  status*: int
  body*: seq[byte]
  token*: string
  requestedUris*: seq[Uri]
  payloads*: seq[string]

proc new*(T: typedesc[PeerIDAuthClientStub]): PeerIDAuthClientStub =
  PeerIDAuthClientStub(
    session: HttpSessionRef.new(),
    rng: rng(),
    serverKey: PrivateKey.random(PKScheme.Ed25519, rng()).get(),
    status: 200,
    token: "somebearer",
  )

proc extractField(data, key: string): string =
  for segment in data.split(","):
    if key in segment:
      return segment.split("=", 1)[1].strip(chars = {' ', '"'})
  ""

proc signAsServer(
    self: PeerIDAuthClientStub,
    challengeServer, hostname: string,
    clientPubkey: PublicKey,
): string =
  var buf = PeerIDAuthPrefix.toBytes()
  for (k, v) in [
    ("challenge-server", challengeServer.toBytes()),
    ("client-public-key", clientPubkey.getBytes().get()),
    ("hostname", hostname.toBytes()),
  ]:
    buf.add PB.encodeVarint(hint(k.len + v.len + 1)).get()
    buf.add (k & "=").toBytes()
    buf.add v
  base64.encode(self.serverKey.sign(buf).get().getBytes(), safe = true)

method get*(
    self: PeerIDAuthClientStub, uri: Uri
): Future[PeerIDAuthResponse] {.
    async: (raises: [PeerIDAuthError, HttpError, CancelledError])
.} =
  self.requestedUris.add(uri)

  let serverPubkey =
    self.serverKey.getPublicKey().get().pubkeyBytes().encode(safe = true)
  var headers = HttpTable.init()
  headers.add(
    "WWW-Authenticate",
    PeerIDAuthPrefix & " challenge-client=\"" & ChallengeClient & "\", public-key=\"" &
      serverPubkey & "\", opaque=\"" & Opaque & "\"",
  )
  PeerIDAuthResponse(status: 200, headers: headers, body: @[])

method post*(
    self: PeerIDAuthClientStub, uri: Uri, payload: string, authHeader: string
): Future[PeerIDAuthResponse] {.async: (raises: [HttpError, CancelledError]).} =
  self.requestedUris.add(uri)
  self.payloads.add(payload)

  var clientPubkey: PublicKey
  try:
    clientPubkey =
      PublicKey.init(decode(authHeader.extractField("public-key")).toBytes()).get()
  except ValueError as exc:
    raiseAssert "stub could not read the client public key: " & exc.msg

  let sig = self.signAsServer(
    authHeader.extractField("challenge-server"), uri.hostname, clientPubkey
  )
  var headers = HttpTable.init()
  headers.add(
    "Authentication-Info",
    PeerIDAuthPrefix & " sig=\"" & sig & "\", bearer=\"" & self.token & "\"",
  )
  PeerIDAuthResponse(status: self.status, headers: headers, body: self.body)
