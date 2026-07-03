# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import base64, strutils, json
import chronos/apps/http/httpclient
import nimcrypto/sha2
import ../../errors
import ../../transports/tls/certificate_ffi
import ../../crypto/rsa

type ACMEError* = object of LPError
type ACMENetworkError* = object of ACMEError

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

proc thumbprint*(key: RsaPrivateKey): string =
  let pubkey = key.getPublicKey()
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

proc createCSR*(
    domain: string, certKeyPair: RsaPrivateKey
): string {.raises: [ACMEError].} =
  let rawSeckey: seq[byte] = certKeyPair.getBytes.valueOr:
    raise newException(ACMEError, "Failed to get RSA private key bytes (DER)")
  let certKey = cert_new_key_t(rawSeckey).valueOr:
    raise newException(ACMEError, "Failed to convert key pair to cert_key_t")
  defer:
    cert_free_key(certKey)

  # create CSR
  let derCSR = cert_signing_req(domain, certKey).valueOr:
    raise newException(ACMEError, "Failed to create CSR")

  base64.encode(derCSR, safe = true)
