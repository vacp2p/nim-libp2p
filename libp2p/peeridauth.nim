import base64, json, strutils
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

type BearerToken* = string
type PeerIDAuthChallenge = string
type PeerIDAuthOpaque = string
type PeerIDAuthSignature = string

type PeerIDAuthApi* = object
  bearer*: Opt[BearerToken]
  session: HttpSessionRef
  rng: ref HmacDrbgContext

type PeerIDAuthAuthenticationResponse* = object
  challengeClient: PeerIDAuthChallenge
  opaque: PeerIDAuthOpaque
  serverPubkey: PublicKey

type PeerIDAuthAuthorizationResponse* = object
  sig: PeerIDAuthSignature
  bearer: BearerToken

type SigParam = object
  k: string
  v: seq[byte]

proc new*(T: typedesc[PeerIDAuthApi], rng: ref HmacDrbgContext): PeerIDAuthApi =
  PeerIDAuthApi(session: HttpSessionRef.new(), rng: rng)

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
    self: PeerIDAuthApi, url: string, payload: string, authHeader: string
): Future[HttpClientResponseRef] {.
    async: (raises: [ACMEError, HttpError, CancelledError])
.} =
  await HttpClientRequestRef
  .post(
    self.session,
    url,
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
    self: PeerIDAuthApi, url: string
): Future[PeerIDAuthAuthenticationResponse] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  let rawResponse =
    try:
      await HttpClientRequestRef.get(self.session, url).get().send()
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

proc requestAuthorization(
    self: PeerIDAuthApi,
    peerInfo: PeerInfo,
    url: string,
    challengeClient: PeerIDAuthChallenge,
    serverPubkey: PublicKey,
    opaque: PeerIDAuthOpaque,
    payload: auto,
): Future[PeerIDAuthAuthorizationResponse] {.
    async: (raises: [PeerIDAuthError, CancelledError])
.} =
  let clientPubkeyB64 = peerInfo.publicKey.pubkeyBytes().encode(safe = true)
  let sig = peerInfo.privateKey.sign(challengeClient, serverPubkey, hostname)
  let authHeader =
    PeerIDAuthPrefix & " public-key=\"" & clientPubkeyB64 & "\"" & ", opaque=\"" & opaque &
    "\"" & ", challenge-server=\"" & self.rng.randomChallenge() & "\"" & ", sig=\"" & sig &
    "\""
  let rawResponse =
    try:
      await self.post(url, $payload, authHeader)
    except HttpError as exc:
      raise newException(
        PeerIDAuthError, "Failed to send Authorization for PeerID Auth", exc
      )

  let authenticationInfo =
    authorizationResponse.headers.getString("authentication-info")

  PeerIDAuthAuthorizationResponse(
    sig: PeerIDAuthSignature(extractField(authenticationInfo, "sig")),
    bearer: BearerToken(extractField(authenticationInfo, "bearer")),
  )

proc authenticate(
    self: PeerIDAuthApi,
    url: string,
    hostname: string,
    peerInfo: PeerInfo,
    payload: auto,
): Future[BearerToken] {.async: (raises: [PeerIDAuthError, CancelledError]).} =
  # Authenticate in three ways as per the PeerID Auth spec
  # https://github.com/libp2p/specs/blob/master/http/peer-id-auth.md

  let authenticationResponse = await self.requestAuthentication(url)

  let authorizationResponse = await self.requestAuthorization(
    peerInfo, url, authenticationResponse.challengeClient,
    authenticationResponse.serverPubkey, payload,
  )

  if not checkSignature(
    authorizationResponse.sig, authenticationResponse.serverPubkey,
    authenticationResponse.challengeServer, peerInfo.publicKey, hostname,
  ):
    raise newException(PeerIDAuthError, "Failed to validate server's signature")

  return authorizationResponse.bearer

proc send*(
    self: PeerIDAuthApi, peerInfo: PeerInfo, url: string, payload: auto
): Future[void] {.async: (raises: [AutoTLSError, PeerIDAuthError, CancelledError]).} =
  if self.bearer.isNone:
    self.bearer = Opt.some(await self.authenticate(url, session, peerInfo, payload))
    return

  let authHeader = PeerIDAuthPrefix & " bearer=\"" & self.bearer.get & "\""
  try:
    await self.post(url, $payload, authHeader)
  except HttpError as exc:
    raise newException(
      PeerIDAuthError, "Failed to send request with bearer token for PeerID Auth", exc
    )

proc close*(self: PeerIDAuthApi): Future[void] {.async: (raises: [CancelledError]).} =
  await self.session.closeWait()
