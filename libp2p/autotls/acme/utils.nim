import base64, strutils, chronos/apps/http/httpclient, json
import ../../errors
import ../../transports/tls/certificate_ffi
import ../../crypto/crypto
import ../../crypto/rsa

type ACMEError* = object of LPError

proc keyOrError*(table: HttpTable, key: string): string {.raises: [ValueError].} =
  if not table.contains(key):
    raise newException(ValueError, "key " & key & " not present in headers")
  table.getString(key)

proc base64UrlEncode*(data: seq[byte]): string =
  ## Encodes data using base64url (RFC 4648 §5) — no padding, URL-safe
  var encoded = base64.encode(data, safe = true)
  encoded.removeSuffix("=")
  encoded.removeSuffix("=")
  return encoded

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

proc getResponseBody*(
    response: HttpClientResponseRef
): Future[JsonNode] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let bodyBytes = await response.getBodyBytes()
    if bodyBytes.len > 0:
      return bytesToString(bodyBytes).parseJson()
    return %*{} # empty body
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    raise
      newException(ACMEError, "Unexpected error occurred while getting body bytes", exc)
  except Exception as exc: # this is required for nim 1.6
    raise
      newException(ACMEError, "Unexpected error occurred while getting body bytes", exc)

proc createCSR*(domain: string): string {.raises: [ACMEError].} =
  var certKey: cert_key_t
  var certCtx: cert_context_t
  var derCSR: ptr cert_buffer = nil

  let personalizationStr = "libp2p_autotls"
  if cert_init_drbg(
    personalizationStr.cstring, personalizationStr.len.csize_t, certCtx.addr
  ) != CERT_SUCCESS:
    raise newException(ACMEError, "Failed to initialize certCtx")
  if cert_generate_key(certCtx, certKey.addr) != CERT_SUCCESS:
    raise newException(ACMEError, "Failed to generate cert key")

  if cert_signing_req(domain.cstring, certKey, derCSR.addr) != CERT_SUCCESS:
    raise newException(ACMEError, "Failed to create CSR")
