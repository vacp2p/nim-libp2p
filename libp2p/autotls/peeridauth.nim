import
  base64,
  json,
  random,
  std/sysrand,
  strformat # TODO: swap sysrand for bearssl functions?
import chronos/apps/http/httpclient, results, chronicles, bio
import ./utils, ../peerinfo, ../crypto/crypto

logScope:
  topics = "libp2p peerid auth"

type SigParam = object
  k: string
  v: seq[byte]

proc randomChallenge(): string =
  randomize()
  let charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  result = ""
  for _ in 0 ..< 48:
    result.add sample(charset)

proc extractField(data, key: string): string {.raises: [PeerIDAuthError].} =
  # Helper to extract quoted value from key
  for segment in data.split(","):
    if key in segment:
      return segment.split("=", 1)[1].strip(chars = {' ', '"'})
  raise newException(PeerIDAuthError, fmt"Could not find {key} in {data}")

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
    buf.add (p.k & "=").toByteSeq
    buf.add p.v
  return buf

proc peerIdSign(
    privateKey: PrivateKey,
    challenge: string,
    publicKey: PublicKey,
    hostname: string,
    clientSender: bool = true,
): string =
  let prefix = "libp2p-PeerID"
  let parts =
    # parts need to be sorted alphabetically by key
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
        SigParam(k: "hostname", v: hostname.toByteSeq),
      ]
  let bytesToSign = genDataToSign(prefix, parts)
  return base64.encode(privateKey.sign(bytesToSign).get().getBytes(), safe = true)

proc peerIdAuthenticate(
    url: string, peerInfo: PeerInfo, payload: JsonNode
): Future[(string, HttpClientResponseRef)] {.
    async: (raises: [AutoTLSError, PeerIDAuthError, CancelledError])
.} =
  # Authenticate in three ways as per the PeerID Auth spec
  # https://github.com/libp2p/specs/blob/master/http/peer-id-auth.md

  # request authentication
  let base36PeerId = encodePeerId(peerInfo.peerId)
  var authStartResponse: HttpClientResponseRef
  try:
    authStartResponse =
      await HttpClientRequestRef.get(HttpSessionRef.new(), url).get().send()
  except HttpError:
    raise newException(PeerIDAuthError, "Failed to start PeerID Auth")

  # TODO: check server's signature
  # www-authenticate
  let wwwAuthenticate = authStartResponse.headers.getString("www-authenticate")
  if wwwAuthenticate == "":
    raise newException(PeerIDAuthError, "www-authenticate not present in response")
  let challengeClient = extractField(wwwAuthenticate, "challenge-client")
  var serverPublicKey: PublicKey
  try:
    serverPublicKey = PublicKey
      .init(decode(extractField(wwwAuthenticate, "public-key")).toByteSeq)
      .get()
  except ValueError:
    raise newException(PeerIDAuthError, "Could not decode public-key")
  let opaque = extractField(wwwAuthenticate, "opaque")

  let hostname = fmt"registration.{AutoTLSDNSServer}" # registration.libp2p.direct
  let clientPubKeyB64 = base64.encode(peerInfo.publicKey.getBytes().get(), safe = true)
  let challengeServer = randomChallenge()
  let sig = peerIdSign(peerInfo.privateKey, challengeClient, serverPublicKey, hostname)
  let authHeader =
    "libp2p-PeerID public-key=\"" & clientPubKeyB64 & "\"" & ", opaque=\"" & opaque &
    "\"" & ", challenge-server=\"" & challengeServer & "\"" & ", sig=\"" & sig & "\""

  # Authorization
  var authorizationResponse: HttpClientResponseRef
  try:
    authorizationResponse = await HttpClientRequestRef
    .post(
      HttpSessionRef.new(),
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
  except HttpError:
    raise newException(PeerIDAuthError, "Failed to send Authorization for PeerID Auth")

  # Bearer token
  return (
    extractField(
      authorizationResponse.headers.getString("authentication-info"), "bearer"
    ),
    authorizationResponse,
  )

proc peerIdAuthSend*(
    url: string,
    peerInfo: PeerInfo,
    payload: JsonNode,
    bearerToken: Opt[string] = Opt.none(string),
): Future[(string, HttpClientResponseRef)] {.
    async: (raises: [AutoTLSError, PeerIDAuthError, CancelledError])
.} =
  if bearerToken.isNone:
    return await peerIdAuthenticate(url, peerInfo, payload)

  let authHeader = "libp2p-PeerID bearer=\"" & bearerToken.get & "\""
  var response: HttpClientResponseRef
  try:
    response = await HttpClientRequestRef
    .post(
      HttpSessionRef.new(),
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
  except HttpError:
    raise newException(
      PeerIDAuthError, "Failed to send request with bearer token for PeerID Auth"
    )

  return (bearerToken.get, response)
