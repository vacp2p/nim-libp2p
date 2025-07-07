# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import base64, json, strutils, uri, times, stew/byteutils
import chronos, chronos/apps/http/httpclient, results, chronicles
import ../peerinfo, ../crypto/crypto, ../varint.nim

logScope:
  topics = "libp2p peeridauth"

const
  NimLibp2pUserAgent = "nim-libp2p"
  PeerIDAuthPrefix* = "libp2p-PeerID"
  ChallengeCharset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  ChallengeDefaultLen = 48

export Domain

type PeerIDAuthClient* = ref object of RootObj
  session: HttpSessionRef
  rng: ref HmacDrbgContext

type PeerIDAuthError* = object of LPError

type PeerIDAuthResponse* = object
  status*: int
  headers*: HttpTable
  body*: seq[byte]

type BearerToken* = object
  token*: string
  expires*: Opt[DateTime]

type PeerIDAuthOpaque* = string
type PeerIDAuthSignature* = string
type PeerIDAuthChallenge* = string

type PeerIDAuthAuthenticationResponse* = object
  challengeClient*: PeerIDAuthChallenge
  opaque*: PeerIDAuthOpaque
  serverPubkey*: PublicKey

type PeerIDAuthAuthorizationResponse* = object
  sig*: PeerIDAuthSignature
  bearer*: BearerToken
  response*: PeerIDAuthResponse

type SigParam = object
  k: string
  v: seq[byte]

proc new*(
    T: typedesc[PeerIDAuthClient], rng: ref HmacDrbgContext = newRng()
): PeerIDAuthClient =
  PeerIDAuthClient(session: HttpSessionRef.new(), rng: rng)

proc sampleChar(
    ctx: var HmacDrbgContext, choices: string
): char {.raises: [ValueError].} =
  ## Samples a random character from the input string using the DRBG context
  if choices.len == 0:
    raise newException(ValueError, "Cannot sample from an empty string")
  var idx: uint32
  ctx.generate(idx)
  return choices[uint32(idx mod uint32(choices.len))]

proc randomChallenge(
    rng: ref HmacDrbgContext, challengeLen: int = ChallengeDefaultLen
): PeerIDAuthChallenge {.raises: [PeerIDAuthError].} =
  var rng = rng[]
  var challenge = ""
  try:
    for _ in 0 ..< challengeLen:
      challenge.add(rng.sampleChar(ChallengeCharset))
  except ValueError as exc:
    raise newException(PeerIDAuthError, "Failed to generate challenge", exc)
  PeerIDAuthChallenge(challenge)

proc extractField(data, key: string): string {.raises: [PeerIDAuthError].} =
  # Helper to extract quoted value from key
  for segment in data.split(","):
    if key in segment:
      return segment.split("=", 1)[1].strip(chars = {' ', '"'})
  raise newException(PeerIDAuthError, "Failed to find " & key & " in " & data)

proc genDataToSign(
    parts: seq[SigParam], prefix: string = PeerIDAuthPrefix
): seq[byte] {.raises: [PeerIDAuthError].} =
  var buf: seq[byte] = prefix.toBytes()
  for p in parts:
    let varintLen = PB.encodeVarint(hint(p.k.len + p.v.len + 1)).valueOr:
      raise newException(PeerIDAuthError, "could not encode fields length to varint")
    buf.add varintLen
    buf.add (p.k & "=").toBytes()
    buf.add p.v
  return buf

proc getSigParams(
    clientSender: bool, hostname: string, challenge: string, publicKey: PublicKey
): seq[SigParam] =
  if clientSender:
    @[
      SigParam(k: "challenge-client", v: challenge.toBytes()),
      SigParam(k: "hostname", v: hostname.toBytes()),
      SigParam(k: "server-public-key", v: publicKey.getBytes().get()),
    ]
  else:
    @[
      SigParam(k: "challenge-server", v: challenge.toBytes()),
      SigParam(k: "client-public-key", v: publicKey.getBytes().get()),
      SigParam(k: "hostname", v: hostname.toBytes()),
    ]

proc sign(
    privateKey: PrivateKey,
    challenge: PeerIDAuthChallenge,
    publicKey: PublicKey,
    hostname: string,
    clientSender: bool = true,
): PeerIDAuthSignature {.raises: [PeerIDAuthError].} =
  let bytesToSign =
    getSigParams(clientSender, hostname, challenge, publicKey).genDataToSign()
  PeerIDAuthSignature(
    base64.encode(privateKey.sign(bytesToSign).get().getBytes(), safe = true)
  )

proc checkSignature*(
    serverSig: PeerIDAuthSignature,
    serverPublicKey: PublicKey,
    challengeServer: PeerIDAuthChallenge,
    clientPublicKey: PublicKey,
    hostname: string,
): bool {.raises: [PeerIDAuthError].} =
  let bytesToSign =
    getSigParams(false, hostname, challengeServer, clientPublicKey).genDataToSign()
  var serverSignature: Signature
  try:
    if not serverSignature.init(base64.decode(serverSig).toBytes()):
      raise newException(
        PeerIDAuthError, "Failed to initialize Signature from base64 encoded sig"
      )
  except ValueError as exc:
    raise newException(PeerIDAuthError, "Failed to decode server's signature", exc)

  serverSignature.verify(
    bytesToSign.toOpenArray(0, bytesToSign.len - 1), serverPublicKey
  )

method post*(
    self: PeerIDAuthClient, uri: Uri, payload: string, authHeader: string
): Future[PeerIDAuthResponse] {.async: (raises: [HttpError, CancelledError]), base.} =
  let rawResponse = await HttpClientRequestRef
  .post(
    self.session,
    $uri,
    body = payload,
    headers = [
      ("Content-Type", "application/json"),
      ("User-Agent", NimLibp2pUserAgent),
      ("Authorization", authHeader),
    ],
  )
  .get()
  .send()

  PeerIDAuthResponse(
    status: rawResponse.status,
    headers: rawResponse.headers,
    body: await rawResponse.getBodyBytes(),
  )

method get*(
    self: PeerIDAuthClient, uri: Uri
): Future[PeerIDAuthResponse] {.
    async: (raises: [PeerIDAuthError, HttpError, CancelledError]), base
.} =
  if self.session.isNil():
    raise newException(PeerIDAuthError, "Session is nil")
  let req = HttpClientRequestRef.get(self.session, $uri).valueOr:
    raise newException(PeerIDAuthError, "Could not get request obj")
  let rawResponse = await req.send()
  PeerIDAuthResponse(
    status: rawResponse.status,
    headers: rawResponse.headers,
    body: await rawResponse.getBodyBytes(),
  )

proc requestAuthentication*(
    self: PeerIDAuthClient, uri: Uri
): Future[PeerIDAuthAuthenticationResponse] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  let response =
    try:
      await self.get(uri)
    except HttpError as exc:
      raise newException(PeerIDAuthError, "Failed to start PeerID Auth", exc)

  let wwwAuthenticate = response.headers.getString("WWW-Authenticate")
  if wwwAuthenticate == "":
    raise newException(PeerIDAuthError, "WWW-authenticate not present in response")

  let serverPubkey: PublicKey =
    try:
      PublicKey.init(decode(extractField(wwwAuthenticate, "public-key")).toBytes()).valueOr:
        raise newException(PeerIDAuthError, "Failed to initialize server public-key")
    except ValueError as exc:
      raise newException(PeerIDAuthError, "Failed to decode server public-key", exc)

  PeerIDAuthAuthenticationResponse(
    challengeClient: extractField(wwwAuthenticate, "challenge-client"),
    opaque: extractField(wwwAuthenticate, "opaque"),
    serverPubkey: serverPubkey,
  )

proc pubkeyBytes*(pubkey: PublicKey): seq[byte] {.raises: [PeerIDAuthError].} =
  try:
    pubkey.getBytes().valueOr:
      raise
        newException(PeerIDAuthError, "Failed to get bytes from PeerInfo's publicKey")
  except ValueError as exc:
    raise newException(
      PeerIDAuthError, "Failed to get bytes from PeerInfo's publicKey", exc
    )

proc parse3339DateTime(
    timeStr: string
): DateTime {.raises: [ValueError, TimeParseError].} =
  let parts = timeStr.split('.')
  let base = parse(parts[0], "yyyy-MM-dd'T'HH:mm:ss")
  let millis = parseInt(parts[1].strip(chars = {'Z'}))
  result = base + initDuration(milliseconds = millis)

proc requestAuthorization*(
    self: PeerIDAuthClient,
    peerInfo: PeerInfo,
    uri: Uri,
    challengeClient: PeerIDAuthChallenge,
    challengeServer: PeerIDAuthChallenge,
    serverPubkey: PublicKey,
    opaque: PeerIDAuthOpaque,
    payload: auto,
): Future[PeerIDAuthAuthorizationResponse] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  let clientPubkeyB64 = peerInfo.publicKey.pubkeyBytes().encode(safe = true)
  let sig = peerInfo.privateKey.sign(challengeClient, serverPubkey, uri.hostname)
  let authHeader =
    PeerIDAuthPrefix & " public-key=\"" & clientPubkeyB64 & "\"" & ", opaque=\"" & opaque &
    "\"" & ", challenge-server=\"" & challengeServer & "\"" & ", sig=\"" & sig & "\""
  let response =
    try:
      await self.post(uri, $payload, authHeader)
    except HttpError as exc:
      raise newException(
        PeerIDAuthError, "Failed to send Authorization for PeerID Auth", exc
      )

  let authenticationInfo = response.headers.getString("authentication-info")

  let bearerExpires =
    try:
      Opt.some(parse3339DateTime(extractField(authenticationInfo, "expires")))
    except ValueError, PeerIDAuthError, TimeParseError:
      Opt.none(DateTime)

  PeerIDAuthAuthorizationResponse(
    sig: PeerIDAuthSignature(extractField(authenticationInfo, "sig")),
    bearer: BearerToken(
      token: extractField(authenticationInfo, "bearer"), expires: bearerExpires
    ),
    response: response,
  )

proc sendWithoutBearer(
    self: PeerIDAuthClient, uri: Uri, peerInfo: PeerInfo, payload: auto
): Future[(BearerToken, PeerIDAuthResponse)] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  # Authenticate in three ways as per the PeerID Auth spec
  # https://github.com/libp2p/specs/blob/master/http/peer-id-auth.md

  let authenticationResponse = await self.requestAuthentication(uri)

  let challengeServer = self.rng.randomChallenge()
  let authorizationResponse = await self.requestAuthorization(
    peerInfo, uri, authenticationResponse.challengeClient, challengeServer,
    authenticationResponse.serverPubkey, authenticationResponse.opaque, payload,
  )

  if not checkSignature(
    authorizationResponse.sig, authenticationResponse.serverPubkey, challengeServer,
    peerInfo.publicKey, uri.hostname,
  ):
    raise newException(PeerIDAuthError, "Failed to validate server's signature")

  return (authorizationResponse.bearer, authorizationResponse.response)

proc sendWithBearer(
    self: PeerIDAuthClient,
    uri: Uri,
    peerInfo: PeerInfo,
    payload: auto,
    bearer: BearerToken,
): Future[(BearerToken, PeerIDAuthResponse)] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  if bearer.expires.isSome() and DateTime(bearer.expires.get) <= now():
    raise newException(PeerIDAuthError, "Bearer expired")
  let authHeader = PeerIDAuthPrefix & " bearer=\"" & bearer.token & "\""
  let response =
    try:
      await self.post(uri, $payload, authHeader)
    except HttpError as exc:
      raise newException(
        PeerIDAuthError, "Failed to send request with bearer token for PeerID Auth", exc
      )
  return (bearer, response)

proc send*(
    self: PeerIDAuthClient,
    uri: Uri,
    peerInfo: PeerInfo,
    payload: auto,
    bearer: Opt[BearerToken] = Opt.none(BearerToken),
): Future[(BearerToken, PeerIDAuthResponse)] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  if bearer.isSome():
    await self.sendWithBearer(uri, peerInfo, payload, bearer.get)
  else:
    await self.sendWithoutBearer(uri, peerInfo, payload)

proc close*(
    self: PeerIDAuthClient
): Future[void] {.async: (raises: [CancelledError]).} =
  await self.session.closeWait()
