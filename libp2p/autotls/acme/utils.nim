import base64, strutils, chronos/apps/http/httpclient, json
import ../../errors

type ACMEError* = object of LPError

proc base64UrlEncode*(data: seq[byte]): string =
  ## Encodes data using base64url (RFC 4648 §5) — no padding, URL-safe
  var encoded = base64.encode(data, safe = true)
  encoded.removeSuffix("=")
  encoded.removeSuffix("=")
  return encoded

proc getResponseBody*(
    response: HttpClientResponseRef
): Future[JsonNode] {.async: (raises: [ACMEError]).} =
  try:
    let responseBody = bytesToString(await response.getBodyBytes()).parseJson()
    return responseBody
  except CatchableError as exc:
    raise
      newException(ACMEError, "Unexpected error occurred while getting body bytes", exc)
  except Exception as exc: # this is required for nim 1.6
    raise
      newException(ACMEError, "Unexpected error occurred while getting body bytes", exc)
