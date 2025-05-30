import
  base64, strutils, stew/base36, chronos/apps/http/httpclient, chronos, json, net, times
import
  ../errors, ../peerid, ../multihash, ../cid, ../multicodec, ../crypto/[crypto, rsa]

type
  GetPrimaryIPError* = object of LPError
  AutoTLSError* = object of LPError
  ACMEError* = object of AutoTLSError
  PeerIDAuthError* = object of AutoTLSError

const
  AutoTLSBroker* = "registration.libp2p.direct"
  AutoTLSDNSServer* = "libp2p.direct"
  HttpOk* = 200
  HttpCreated* = 201

proc sampleChar*(ctx: var HmacDrbgContext, choices: string): char =
  ## Samples a random character from the input string using the DRBG context
  if choices.len == 0:
    raise newException(ValueError, "Cannot sample from an empty string")
  var idx: uint32
  ctx.generate(idx)
  return choices[uint32(idx mod uint32(choices.len))]

proc base64UrlEncode*(data: seq[byte]): string =
  ## Encodes data using base64url (RFC 4648 §5) — no padding, URL-safe
  var encoded = base64.encode(data, safe = true)
  encoded.removeSuffix("=")
  encoded.removeSuffix("=")
  return encoded

proc isPublicIPv4*(ip: IpAddress): bool =
  if ip.family != IpAddressFamily.IPv4:
    return false
  let ip = $ip
  return
    not (
      ip.startsWith("10.") or
      (ip.startsWith("172.") and parseInt(ip.split(".")[1]) in 16 .. 31) or
      ip.startsWith("192.168.") or ip.startsWith("127.") or ip.startsWith("169.254.")
    )

proc asMoment*(dt: DateTime): Moment =
  let unixTime: int64 = dt.toTime.toUnix
  return Moment.init(unixTime, Second)

proc encodePeerId*(peerId: PeerId): string {.raises: [AutoTLSError].} =
  var mh: MultiHash
  let decodeResult = MultiHash.decode(peerId.data, mh)
  if decodeResult.isErr or decodeResult.get() == -1:
    raise
      newException(AutoTLSError, "Failed to decode PeerId: invalid multihash format")

  let cidResult = Cid.init(CIDv1, multiCodec("libp2p-key"), mh)
  if cidResult.isErr:
    raise newException(AutoTLSError, "Failed to initialize CID from multihash")

  return Base36.encode(cidResult.get().data.buffer)

proc checkedParseJson*(bodyBytes: string): JsonNode {.raises: [ValueError].} =
  # This is so that we don't need to catch Exceptions directly
  # since we support 1.6.16 and parseJson before nim 2 didn't have explicit .raises. pragmas
  try:
    return parseJson(bodyBytes)
  except Exception as exc:
    raise newException(ValueError, "Error while parsing JSON", exc)

proc checkedGetPrimaryIPAddr*(): IpAddress {.raises: [GetPrimaryIPError].} =
  # This is so that we don't need to catch Exceptions directly
  # since we support 1.6.16 and getPrimaryIPAddr before nim 2 didn't have explicit .raises. pragmas
  try:
    return getPrimaryIPAddr()
  except Exception as exc:
    raise newException(GetPrimaryIPError, "Error while getting primary IP address", exc)

proc getJSONField*(node: JsonNode, field: string): JsonNode {.raises: [ACMEError].} =
  try:
    return node[field]
  except CatchableError:
    raise newException(ACMEError, "'" & field & "' field not found in JSON")

proc getParsedResponseBody*(
    response: HttpClientResponseRef
): Future[JsonNode] {.async: (raises: [ACMEError]).} =
  try:
    let responseBody = bytesToString(await response.getBodyBytes()).checkedParseJson()
    return responseBody
  except ValueError as exc:
    raise newException(ACMEError, "Unable to parse JSON body", exc)
  except OSError as exc:
    raise newException(ACMEError, "Unable to parse JSON body", exc)
  except IOError as exc:
    raise newException(ACMEError, "Unable to parse JSON body", exc)
  except CatchableError as exc:
    raise
      newException(ACMEError, "Unexpected error occurred while getting body bytes", exc)

proc thumbprint*(key: KeyPair): string =
  doAssert key.seckey.scheme == PKScheme.RSA, "unsupported keytype"
  let pubkey = key.pubkey.rsakey
  let nArray = @(getArray(pubkey.buffer, pubkey.key.n, pubkey.key.nlen))
  let eArray = @(getArray(pubkey.buffer, pubkey.key.e, pubkey.key.elen))

  let n = base64UrlEncode(nArray)
  let e = base64UrlEncode(eArray)
  let keyJson = %*{"e": e, "kty": "RSA", "n": n}
  let digest = sha256.digest($keyJson)
  return base64UrlEncode(@(digest.data))
