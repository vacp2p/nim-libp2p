import options, json, base64, sequtils
from times import DateTime, parse
import chronos/apps/http/httpclient, jwt, results, bearssl/pem

import ./utils
import ../crypto/crypto
import ../crypto/rsa
import ../transports/tls/certificate_ffi
import ../transports/tls/certificate

const
  LetsEncryptURL* = "https://acme-v02.api.letsencrypt.org"
  LetsEncryptURLStaging* = "https://acme-staging-v02.api.letsencrypt.org"
  Alg = "RS256"
  DefaultChalCompletedRetries = 10
  DefaultChalCompletedRetryTime = 1.seconds
  DefaultFinalizeRetries = 10
  DefaultFinalizeRetryTime = 1.seconds
  DefaultRandStringSize = 256

type ACMEAccount* = object
  status*: Opt[string]
  contact*: Opt[seq[string]]
  key*: KeyPair
  session*: HttpSessionRef
  kid*: Opt[string]
  newNonceURL: string
  newAccountURL: string
  newOrderURL: string
  acmeServerURL: string

proc new*(
    T: typedesc[ACMEAccount],
    key: KeyPair,
    status: Opt[string] = Opt.none(string),
    contact: Opt[seq[string]] = Opt.none(seq[string]),
    kid: Opt[string] = Opt.none(string),
    acmeServerURL: string = LetsEncryptURL,
): Future[ref ACMEAccount] {.async: (raises: [ACMEError, CancelledError]).} =
  let session = HttpSessionRef.new()
  var directory: JsonNode
  try:
    let directoryResponse =
      await HttpClientRequestRef.get(session, acmeServerURL & "/directory").get().send()
    directory = bytesToString(await directoryResponse.getBodyBytes()).checkedParseJson()
  except HttpError as exc:
    raise newException(ACMEError, "Failed to connect to ACME server", exc)
  except ValueError as exc:
    raise newException(ACMEError, "Unable to parse JSON", exc)
  except OSError as exc:
    raise newException(ACMEError, "Unable to parse JSON", exc)
  except IOError as exc:
    raise newException(ACMEError, "Unable to parse JSON", exc)

  let acc = new(ACMEAccount)
  acc.status = status
  acc.contact = contact
  acc.kid = kid
  acc.key = key
  acc.session = session
  acc.newNonceURL = directory.getJSONField("newNonce").getStr
  acc.newAccountURL = directory.getJSONField("newAccount").getStr
  acc.newOrderURL = directory.getJSONField("newOrder").getStr
  acc.acmeServerURL = acmeServerURL
  return acc

proc newNonce(
    self: ref ACMEAccount
): Future[string] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let resp =
      await HttpClientRequestRef.get(self.session, self.newNonceURL).get().send()
    return resp.headers.getString("Replay-Nonce")
  except HttpError as exc:
    raise newException(ACMEError, "Failed to request new nonce from ACME server", exc)

# TODO: save n and e in account so we don't have to recalculate every time
proc acmeHeader(
    self: ref ACMEAccount, url: string, needsJwk: bool, kid: string = ""
): Future[JsonNode] {.async: (raises: [ACMEError, CancelledError]).} =
  # TODO: check if scheme is RSA
  let pubkey = self.key.pubkey.rsakey
  let nArray = @(getArray(pubkey.buffer, pubkey.key.n, pubkey.key.nlen))
  let eArray = @(getArray(pubkey.buffer, pubkey.key.e, pubkey.key.elen))
  let n = base64UrlEncode(nArray)
  let e = base64UrlEncode(eArray)

  let newNonce = await self.newNonce()
  var header = %*{"alg": Alg, "typ": "JWT", "nonce": newNonce, "url": url}
  if needsJwk:
    header["jwk"] = %*{"kty": "RSA", "n": n, "e": e}
  else:
    if self.kid.isNone:
      raise newException(ACMEError, "no kid registered for account")
    header["kid"] = %*(self.kid.get)
  return header

proc signedAcmeRequest(
    self: ref ACMEAccount, url: string, payload: JsonNode, needsJwk: bool = false
): Future[HttpClientResponseRef] {.async: (raises: [ACMEError, CancelledError]).} =
  let acmeHeader = await self.acmeHeader(url, needsJwk)
  var token: JWT
  var body: JsonNode
  try:
    token = toJWT(%*{"header": acmeHeader, "claims": payload})
    let derPrivKey = self.key.seckey.rsakey.getBytes.get
    let pemPrivKey: string = pemEncode(derPrivKey, "PRIVATE KEY")
    token.sign(pemPrivKey)
    body = token.toFlattenedJson()
  except CatchableError as exc:
    raise newException(ACMEError, "Failed to create JWT", exc)
  try:
    return await HttpClientRequestRef
    .post(
      self.session,
      url,
      body = $body,
      headers = [("Content-Type", "application/jose+json")],
    )
    .get()
    .send()
  except HttpError as exc:
    raise newException(ACMEError, "Failed to send HTTP request to the ACME server", exc)

proc register*(self: ref ACMEAccount) {.async: (raises: [ACMEError, CancelledError]).} =
  if self.kid.isSome:
    # already registered
    return

  let payload = %*{"termsOfServiceAgreed": true}

  let response =
    await self.signedAcmeRequest(self.newAccountURL, payload, needsJwk = true)
  let jsonResponseBody = await response.getParsedResponseBody()
  if response.status != HttpCreated:
    raise newException(
      ACMEError, "Unable to register with ACME server: " & $jsonResponseBody
    )
  self.kid = Opt.some(response.headers.getString("location"))
  self.status = Opt.some(jsonResponseBody.getJSONField("status").getStr)

proc requestChallenge*(
    self: ref ACMEAccount, domains: seq[string]
): Future[(JsonNode, string, string)] {.async: (raises: [ACMEError, CancelledError]).} =
  # request challenge from ACME server
  var identifiers: seq[JsonNode] = domains.mapIt(%*{"type": "dns", "value": it})

  let orderPayload = %*{"identifiers": identifiers}

  let challengeResponse = await self.signedAcmeRequest(self.newOrderURL, orderPayload)
  let challengeResponseBody = await challengeResponse.getParsedResponseBody()
  let orderURL = challengeResponse.headers.getString("location")
  if orderURL == "":
    raise newException(ACMEError, "'location' header not found in ACME response")
  let finalizeURL = challengeResponseBody.getJSONField("finalize").getStr

  # get challenges
  let authzURL = challengeResponseBody.getJSONField("authorizations")[0].getStr
  let authzResponseBody =
    try:
      let authzResponse =
        await HttpClientRequestRef.get(self.session, authzURL).get().send()
      await authzResponse.getParsedResponseBody()
    except CatchableError as exc:
      raise newException(ACMEError, "Failed to request challenge", exc)

  let challenges = authzResponseBody.getJSONField("challenges")
  var dns01: JsonNode = nil
  for item in challenges:
    if item.getJSONField("type").getStr == "dns-01":
      dns01 = item
      break
  if dns01.isNil:
    raise newException(ACMEError, "DNS01 challenge not found in ACME response")

  return (dns01, finalizeURL, orderURL)

proc notifyChallengeCompleted*(
    self: ref ACMEAccount, chalURL: string, retries: int = DefaultChalCompletedRetries
): Future[void] {.async: (raises: [ACMEError, CancelledError]).} =
  let emptyPayload = newJObject()
  let completedResponse = await self.signedAcmeRequest(chalURL, emptyPayload)
  if completedResponse.status != HttpOk:
    raise newException(
      ACMEError,
      "Failed got HTTP status code " & $completedResponse.status &
        " while sending completed message to ACME server",
    )

  var completedResponseBody: JsonNode
  try:
    completedResponseBody =
      bytesToString(await completedResponse.getBodyBytes()).checkedParseJson()
  except HttpError as exc:
    raise newException(ACMEError, "Failed to connect to ACME server", exc)
  except ValueError as exc:
    raise newException(
      ACMEError, "Unexpected error while signaling challenge completion", exc
    )

  let checkURL = completedResponseBody.getJSONField("url").getStr
  # check until acme server is done (poll validation)
  for _ in 0 .. retries:
    var checkResponse: HttpClientResponseRef
    var checkResponseBody: JsonNode
    try:
      checkResponse =
        await HttpClientRequestRef.get(self.session, checkURL).get().send()
      checkResponseBody =
        bytesToString(await checkResponse.getBodyBytes()).checkedParseJson()
    except HttpError as exc:
      raise newException(ACMEError, "Failed to connect to ACME server", exc)
    except ValueError as exc:
      raise newException(
        ACMEError, "Unexpected error while signaling challenge completion", exc
      )
    let status = checkResponseBody.getJSONField("status").getStr
    case status
    of "pending":
      var retryAfter: Duration
      try:
        retryAfter = parseInt(checkResponse.headers.getString("Retry-After")).seconds
      except ValueError:
        retryAfter = DefaultChalCompletedRetryTime
      await sleepAsync(retryAfter) # try again after some delay
    of "valid":
      return
    else:
      raise newException(
        ACMEError, "Failed challenge completion: expected 'valid', got '" & status & "'"
      )

proc finalizeCertificate*(
    self: ref ACMEAccount,
    domain: string,
    finalizeURL: string,
    orderURL: string,
    retries: int = DefaultFinalizeRetries,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
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

  let b64CSR = base64.encode(derCSR.toSeq, safe = true)
  let payload = %*{"csr": b64CSR}

  # send finalize request
  let finalizedResponse = await self.signedAcmeRequest(finalizeURL, payload)
  if finalizedResponse.status != HttpOk:
    raise newException(ACMEError, "Failed to request cert finalization")

  # keep checking order until it's finalized
  var checkResponse: HttpClientResponseRef
  var checkResponseBody: JsonNode
  for _ in 0 .. retries:
    let finalizedResponse = await self.signedAcmeRequest(finalizeURL, payload)
    try:
      checkResponse =
        await HttpClientRequestRef.get(self.session, orderURL).get().send()
      checkResponseBody =
        bytesToString(await checkResponse.getBodyBytes()).checkedParseJson()
    except ValueError as exc:
      raise
        newException(ACMEError, "JSON parsing error while finalizing certificate", exc)
    except CatchableError as exc:
      raise
        newException(ACMEError, "Unexpected error while finalizing certificate", exc)

    let status = checkResponseBody.getJSONField("status").getStr
    case status
    of "valid":
      return true
    of "processing":
      var retryAfter: Duration
      try:
        retryAfter = parseInt(checkResponse.headers.getString("Retry-After")).seconds
      except ValueError:
        retryAfter = DefaultFinalizeRetryTime
      await sleepAsync(retryAfter) # try again after some delay
    else:
      return false

  return false

proc downloadCertificate*(
    self: ref ACMEAccount, orderURL: string
): Future[(string, DateTime)] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let downloadResponse =
      await HttpClientRequestRef.get(self.session, orderURL).get().send()

    if downloadResponse.status != HttpOk:
      raise newException(ACMEError, "Failed to download certificate")

    let certificateInfoBody =
      bytesToString(await downloadResponse.getBodyBytes()).checkedParseJson()

    let certificateDownloadURL = certificateInfoBody.getJSONField("certificate").getStr
    let certificateExpiry = parse(
      certificateInfoBody.getJSONField("expires").getStr, "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )

    let certificateResponse =
      await HttpClientRequestRef.get(self.session, certificateDownloadURL).get().send()
    let rawCertificate = bytesToString(await certificateResponse.getBodyBytes())
    return (rawCertificate, certificateExpiry)
  except HttpError:
    raise newException(ACMEError, "Failed to connect to ACME server")
  except ValueError as exc:
    raise newException(ACMEError, "Unexpected error while downloading certificate", exc)
