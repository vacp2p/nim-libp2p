import base64, strutils, chronos/apps/http/httpclient, json
import ../../errors
import ../../transports/tls/certificate_ffi

type ACMEError* = object of LPError

proc base64UrlEncode*(data: seq[byte]): string =
  ## Encodes data using base64url (RFC 4648 §5) — no padding, URL-safe
  var encoded = base64.encode(data, safe = true)
  encoded.removeSuffix("=")
  encoded.removeSuffix("=")
  return encoded

proc getResponseBody*(
    response: HttpClientResponseRef
): Future[JsonNode] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let responseBody = bytesToString(await response.getBodyBytes()).parseJson()
    return responseBody
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
