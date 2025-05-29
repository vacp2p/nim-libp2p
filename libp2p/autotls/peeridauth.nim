import base64, json, strutils
import chronos/apps/http/httpclient, results, chronicles, bio
import ./utils, ../peerinfo, ../crypto/crypto

logScope:
  topics = "libp2p peerid auth"

const PeerIDAuthPrefix = "libp2p-PeerID"
const ChallengeCharset =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
const ChallengeDefaultLen = 48

type SigParam = object
  k: string
  v: seq[byte]

proc randomChallenge(
    rng: ref HmacDrbgContext, challengeLen: int = ChallengeDefaultLen
): string =
  var rng = rng[]
  var challenge = ""
  for _ in 0 ..< challengeLen:
    challenge.add(rng.sampleChar(ChallengeCharset))
  challenge

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

proc genDataToSign(prefix: string, parts: seq[SigParam]): seq[byte] =
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

proc peerIdSign(
    privateKey: PrivateKey,
    challenge: string,
    publicKey: PublicKey,
    hostname: string,
    clientSender: bool = true,
): string =
  let parts = getSigParams(clientSender, hostname, challenge, publicKey)
  let bytesToSign = genDataToSign(PeerIDAuthPrefix, parts)
  return base64.encode(privateKey.sign(bytesToSign).get().getBytes(), safe = true)

proc checkSignature(
    serverSig: string,
    serverPublicKey: PublicKey,
    challengeServer: string,
    clientPublicKey: PublicKey,
    hostname: string,
): bool {.raises: [PeerIDAuthError].} =
  let parts = getSigParams(false, hostname, challengeServer, clientPublicKey)
  let signedBytes = genDataToSign(PeerIDAuthPrefix, parts)
  var serverSignature: Signature
  try:
    if not serverSignature.init(base64.decode(serverSig).toByteSeq()):
      raise newException(
        PeerIDAuthError, "Failed to initialize Signature from base64 encoded sig"
      )
  except ValueError as exc:
    raise newException(PeerIDAuthError, "Failed to decode server's signature", exc)
  return serverSignature.verify(
    signedBytes.toOpenArray(0, signedBytes.len - 1), serverPublicKey
  )

proc peerIdAuthenticate(
    url: string,
    session: HttpSessionRef,
    peerInfo: PeerInfo,
    payload: JsonNode,
    rng: ref HmacDrbgContext,
): Future[(string, HttpClientResponseRef)] {.
    async: (raises: [AutoTLSError, PeerIDAuthError, CancelledError])
.} =
  # Authenticate in three ways as per the PeerID Auth spec
  # https://github.com/libp2p/specs/blob/master/http/peer-id-auth.md

  # request authentication
  let base36PeerId = encodePeerId(peerInfo.peerId)
  var authStartResponse: HttpClientResponseRef
  try:
    authStartResponse = await HttpClientRequestRef.get(session, url).get().send()
  except HttpError as exc:
    raise newException(PeerIDAuthError, "Failed to start PeerID Auth", exc)

  # www-authenticate
  let wwwAuthenticate = authStartResponse.headers.getString("WWW-Authenticate")
  if wwwAuthenticate == "":
    raise newException(PeerIDAuthError, "WWW-authenticate not present in response")
  let challengeClient = extractField(wwwAuthenticate, "challenge-client")

  let serverPublicKey: PublicKey =
    try:
      PublicKey.init(decode(extractField(wwwAuthenticate, "public-key")).toByteSeq()).valueOr:
        raise newException(PeerIDAuthError, "Failed to initialize public-key")
    except ValueError as exc:
      raise newException(PeerIDAuthError, "Failed to decode public-key", exc)

  let opaque = extractField(wwwAuthenticate, "opaque")

  let publicKeyBytes: seq[byte] =
    try:
      peerInfo.publicKey.getBytes().valueOr:
        raise
          newException(PeerIDAuthError, "Failed to get bytes from PeerInfo's publicKey")
    except ValueError as exc:
      raise newException(
        PeerIDAuthError, "Failed to get bytes from PeerInfo's publicKey", exc
      )

  let hostname = AutoTLSBroker # registration.libp2p.direct

  let clientPubKeyB64 = base64.encode(publicKeyBytes, safe = true)
  let challengeServer: string =
    try:
      randomChallenge(rng)
    except ValueError as exc:
      raise newException(PeerIDAuthError, "Failed to generate challenge", exc)

  let sig = peerIdSign(peerInfo.privateKey, challengeClient, serverPublicKey, hostname)
  let authHeader =
    PeerIDAuthPrefix & " public-key=\"" & clientPubKeyB64 & "\"" & ", opaque=\"" & opaque &
    "\"" & ", challenge-server=\"" & challengeServer & "\"" & ", sig=\"" & sig & "\""

  # Authorization
  let authorizationResponse: HttpClientResponseRef =
    try:
      await HttpClientRequestRef
      .post(
        session,
        url,
        body = $payload,
        headers = [
          ("Content-Type", "application/json"),
          ("User-Agent", "nim-libp2p"),
          ("authorization", authHeader),
        ],
      )
      .get()
      .send()
    except HttpError as exc:
      raise newException(
        PeerIDAuthError, "Failed to send Authorization for PeerID Auth", exc
      )

  # check server's signature
  let serverSig =
    extractField(authorizationResponse.headers.getString("authentication-info"), "sig")
  if not checkSignature(
    serverSig, serverPublicKey, challengeServer, peerInfo.publicKey, hostname
  ):
    raise newException(PeerIDAuthError, "Failed to validate server's signature")

  # Bearer token
  return (
    extractField(
      authorizationResponse.headers.getString("authentication-info"), "bearer"
    ),
    authorizationResponse,
  )

proc peerIdAuthSend*(
    url: string,
    session: HttpSessionRef,
    peerInfo: PeerInfo,
    payload: JsonNode,
    rng: ref HmacDrbgContext,
    bearerToken: Opt[string] = Opt.none(string),
): Future[(string, HttpClientResponseRef)] {.
    async: (raises: [AutoTLSError, PeerIDAuthError, CancelledError])
.} =
  if bearerToken.isNone:
    return await peerIdAuthenticate(url, session, peerInfo, payload, rng)

  let authHeader = PeerIDAuthPrefix & " bearer=\"" & bearerToken.get & "\""
  var response: HttpClientResponseRef
  try:
    response = await HttpClientRequestRef
    .post(
      session,
      url,
      body = $payload,
      headers = [
        ("Content-Type", "application/json"),
        ("User-Agent", "nim-libp2p"),
        ("Authorization", authHeader),
      ],
    )
    .get()
    .send()
  except HttpError as exc:
    raise newException(
      PeerIDAuthError, "Failed to send request with bearer token for PeerID Auth", exc
    )
  return (bearerToken.get, response)
