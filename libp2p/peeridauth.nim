import base64, json, strutils, uri, times
import chronos/apps/http/httpclient, results, chronicles, bio
import ./peerinfo, ./crypto/crypto

logScope:
  topics = "libp2p peerid auth"

const NimLibp2pUserAgent = "nim-libp2p"
const PeerIDAuthPrefix = "libp2p-PeerID"
const ChallengeCharset =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
const ChallengeDefaultLen = 48

type PeerIDAuthError* = object of LPError

type BearerToken* = object
  token*: string
  expires*: Opt[DateTime]

type PeerIDAuthChallenge = string
type PeerIDAuthOpaque = string
type PeerIDAuthSignature = string

type PeerIDAuthApi* = object
  session: HttpSessionRef
  rng: ref HmacDrbgContext

type PeerIDAuthAuthenticationResponse* = object
  challengeClient: PeerIDAuthChallenge
  opaque: PeerIDAuthOpaque
  serverPubkey: PublicKey

type PeerIDAuthAuthorizationResponse* = object
  sig: PeerIDAuthSignature
  bearer: BearerToken
  rawResponse: HttpClientResponseRef

type SigParam = object
  k: string
  v: seq[byte]

proc new*(T: typedesc[PeerIDAuthApi], rng: ref HmacDrbgContext): PeerIDAuthApi =
  PeerIDAuthApi(session: HttpSessionRef.new(), rng: rng)

proc sampleChar(ctx: var HmacDrbgContext, choices: string): char =
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

proc encodeVarint(n: int): seq[byte] =
  var varInt: seq[byte] = @[]
  var x = uint64(n)
  while x != 0:
    var byteVal = byte(x and 0x7F)
    x = x shr 7
    if x != 0:
      byteVal = byteVal or 0x80
    varInt.add(byteVal)
  return varInt

proc genDataToSign(parts: seq[SigParam], prefix: string = PeerIDAuthPrefix): seq[byte] =
  var buf: seq[byte] = prefix.toByteSeq()
  for p in parts:
    buf.add encodeVarint(p.k.len + p.v.len + 1)
    buf.add (p.k & "=").toByteSeq()
    buf.add p.v
  return buf

proc getSigParams(
    clientSender: bool, hostname: string, challenge: string, publicKey: PublicKey
): seq[SigParam] =
  if clientSender:
    @[
      SigParam(k: "challenge-client", v: challenge.toByteSeq()),
      SigParam(k: "hostname", v: hostname.toByteSeq()),
      SigParam(k: "server-public-key", v: publicKey.getBytes().get()),
    ]
  else:
    @[
      SigParam(k: "challenge-server", v: challenge.toByteSeq()),
      SigParam(k: "client-public-key", v: publicKey.getBytes().get()),
      SigParam(k: "hostname", v: hostname.toByteSeq()),
    ]

proc sign(
    privateKey: PrivateKey,
    challenge: PeerIDAuthChallenge,
    publicKey: PublicKey,
    hostname: string,
    clientSender: bool = true,
): PeerIDAuthSignature =
  let bytesToSign =
    getSigParams(clientSender, hostname, challenge, publicKey).genDataToSign()
  PeerIDAuthSignature(
    base64.encode(privateKey.sign(bytesToSign).get().getBytes(), safe = true)
  )

proc checkSignature(
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
    if not serverSignature.init(base64.decode(serverSig).toByteSeq()):
      raise newException(
        PeerIDAuthError, "Failed to initialize Signature from base64 encoded sig"
      )
  except ValueError as exc:
    raise newException(PeerIDAuthError, "Failed to decode server's signature", exc)

  serverSignature.verify(
    bytesToSign.toOpenArray(0, bytesToSign.len - 1), serverPublicKey
  )

proc post(
    self: PeerIDAuthApi, uri: string, payload: string, authHeader: string
): Future[HttpClientResponseRef] {.async: (raises: [HttpError, CancelledError]).} =
  await HttpClientRequestRef
  .post(
    self.session,
    uri,
    body = payload,
    headers = [
      ("Content-Type", "application/json"),
      ("User-Agent", NimLibp2pUserAgent),
      ("authorization", authHeader),
    ],
  )
  .get()
  .send()

proc requestAuthentication(
    self: PeerIDAuthApi, uri: Uri
): Future[PeerIDAuthAuthenticationResponse] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  let rawResponse =
    try:
      await HttpClientRequestRef.get(self.session, $uri).get().send()
    except HttpError as exc:
      raise newException(PeerIDAuthError, "Failed to start PeerID Auth", exc)

  let wwwAuthenticate = rawResponse.headers.getString("WWW-Authenticate")
  if wwwAuthenticate == "":
    raise newException(PeerIDAuthError, "WWW-authenticate not present in response")

  let serverPubkey: PublicKey =
    try:
      PublicKey.init(decode(extractField(wwwAuthenticate, "public-key")).toByteSeq()).valueOr:
        raise newException(PeerIDAuthError, "Failed to initialize server public-key")
    except ValueError as exc:
      raise newException(PeerIDAuthError, "Failed to decode server public-key", exc)

  PeerIDAuthAuthenticationResponse(
    challengeClient: extractField(wwwAuthenticate, "challenge-client"),
    opaque: extractField(wwwAuthenticate, "opaque"),
    serverPubkey: serverPubkey,
  )

proc pubkeyBytes(pubkey: PublicKey): seq[byte] {.raises: [PeerIDAuthError].} =
  try:
    pubkey.getBytes().valueOr:
      raise
        newException(PeerIDAuthError, "Failed to get bytes from PeerInfo's publicKey")
  except ValueError as exc:
    raise newException(
      PeerIDAuthError, "Failed to get bytes from PeerInfo's publicKey", exc
    )

proc parse3339DateTime(timeStr: string): DateTime =
  let parts = timeStr.split('.')
  let base = parse(parts[0], "yyyy-MM-dd'T'HH:mm:ss")
  let millis = parseInt(parts[1].strip(chars = {'Z'}))
  result = base + initDuration(milliseconds = millis)

proc requestAuthorization(
    self: PeerIDAuthApi,
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
  let rawResponse =
    try:
      await self.post($uri, $payload, authHeader)
    except HttpError as exc:
      raise newException(
        PeerIDAuthError, "Failed to send Authorization for PeerID Auth", exc
      )

  let authenticationInfo = rawResponse.headers.getString("authentication-info")

  let bearerExpires =
    try:
      Opt.some(parse3339DateTime(extractField(authenticationInfo, "expires")))
    except ValueError, PeerIDAuthError:
      Opt.none(DateTime)

  PeerIDAuthAuthorizationResponse(
    sig: PeerIDAuthSignature(extractField(authenticationInfo, "sig")),
    bearer: BearerToken(
      token: extractField(authenticationInfo, "bearer"), expires: bearerExpires
    ),
    rawResponse: rawResponse,
  )

proc sendWithoutBearer(
    self: PeerIDAuthApi, uri: Uri, peerInfo: PeerInfo, payload: auto
): Future[(BearerToken, HttpClientResponseRef)] {.
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

  return (authorizationResponse.bearer, authorizationResponse.rawResponse)

proc sendWithBearer(
    self: PeerIDAuthApi,
    uri: Uri,
    peerInfo: PeerInfo,
    payload: auto,
    bearer: BearerToken,
): Future[(BearerToken, HttpClientResponseRef)] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  if bearer.expires.isSome and DateTime(bearer.expires.get) <= now():
    raise newException(PeerIDAuthError, "Bearer expired")
  let authHeader = PeerIDAuthPrefix & " bearer=\"" & bearer.token & "\""
  let rawResponse =
    try:
      await self.post($uri, $payload, authHeader)
    except HttpError as exc:
      raise newException(
        PeerIDAuthError, "Failed to send request with bearer token for PeerID Auth", exc
      )
  return (bearer, rawResponse)

proc send*(
    self: PeerIDAuthApi,
    uri: Uri,
    peerInfo: PeerInfo,
    payload: auto,
    bearer: BearerToken = BearerToken(),
): Future[(BearerToken, HttpClientResponseRef)] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  if bearer.token == "":
    await self.sendWithoutBearer(uri, peerInfo, payload)
  else:
    await self.sendWithBearer(uri, peerInfo, payload, bearer)

proc close*(self: PeerIDAuthApi): Future[void] {.async: (raises: [CancelledError]).} =
  await self.session.closeWait()
