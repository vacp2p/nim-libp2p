import
  base64, strutils, stew/base36, chronos/apps/http/httpclient, json, net, std/sysrand
import
  ../errors, ../peerid, ../multihash, ../cid, ../multicodec, ../crypto/[crypto, rsa]

type AutoTLSError* = object of LPError
type ACMEError* = object of AutoTLSError
type PeerIDAuthError* = object of AutoTLSError

const
  AutoTLSBroker* = "https://registration.libp2p.direct"
  AutoTLSDNSServer* = "libp2p.direct"

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

proc getParsedResponseBody*(
    response: HttpClientResponseRef
): Future[JsonNode] {.async: (raises: [ACMEError]).} =
  try:
    let responseBody = bytesToString(await response.getBodyBytes()).parseJson()
    return responseBody
  except ValueError, OSError, IOError:
    raise newException(ACMEError, "Unable to parse JSON body")
  except Exception as e:
    raise newException(
      ACMEError, "Unexpected error occurred while getting body bytes: " & e.msg
    )

proc getJSONField*(node: JsonNode, field: string): JsonNode {.raises: [ACMEError].} =
  try:
    return node[field]
  except:
    raise newException(ACMEError, "'" & field & "' field not found in JSON")

proc thumbprint*(key: KeyPair): string =
  # TODO: check if scheme is RSA
  let pubkey = key.pubkey.rsakey
  let nArray = @(getArray(pubkey.buffer, pubkey.key.n, pubkey.key.nlen))
  let eArray = @(getArray(pubkey.buffer, pubkey.key.e, pubkey.key.elen))

  let n = base64UrlEncode(nArray)
  let e = base64UrlEncode(eArray)
  let keyJson = %*{"e": e, "kty": "RSA", "n": n}
  # TODO: https://www.rfc-editor.org/rfc/rfc7638
  let digest = sha256.digest($keyJson)
  return base64UrlEncode(@(digest.data))

proc urandomToCString*(size: int): cstring =
  let randBytes = urandom(size)
  result = cast[cstring](alloc(size + 1)) # +1 for null terminator
  for i in 0 ..< size:
    result[i] = char(randBytes[i])
  result[size] = '\0' # Null-terminate
