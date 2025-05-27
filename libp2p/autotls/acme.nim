import options, json, base64
from times import DateTime, parse
import chronos/apps/http/httpclient, jwt, results, bearssl/pem

import ./utils
import ../crypto/crypto
import ../crypto/rsa
import ../transports/tls/certificate_ffi
import ../transports/tls/certificate

# TODO: change staging to actual url
const
  LetsEncryptURL* = "https://acme-v02.api.letsencrypt.org"
  LetsEncryptURLStaging* = "https://acme-staging-v02.api.letsencrypt.org"
  Alg = "RS256"

type ACMEAccount* = object
  status*: Opt[string]
  contact*: Opt[seq[string]]
  key*: KeyPair
  session*: HttpSessionRef
  kid*: Opt[string]
  directory: JsonNode
  acmeServerURL: string

proc new*(
    T: typedesc[ACMEAccount],
    key: KeyPair,
    status: Opt[string] = Opt.none(string),
    contact: Opt[seq[string]] = Opt.none(seq[string]),
    kid: Opt[string] = Opt.none(string),
    acmeServerURL: string = LetsEncryptURL,
): Future[ref ACMEAccount] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let session = HttpSessionRef.new()
    let directoryResponse =
      await HttpClientRequestRef.get(session, acmeServerURL & "/directory").get().send()
    let directory = bytesToString(await directoryResponse.getBodyBytes()).parseJson()

    let acc = new(ACMEAccount)
    acc.status = status
    acc.contact = contact
    acc.kid = kid
    acc.key = key
    acc.session = session
    acc.directory = directory
    acc.acmeServerURL = acmeServerURL
    return acc
  except HttpError as exc:
    raise newException(ACMEError, "Failed to connect to ACME server", exc)
  except ValueError as exc:
    raise newException(ACMEError, "Unable to parse JSON", exc)
  except OSError as exc:
    raise newException(ACMEError, "Unable to parse JSON", exc)
  except IOError as exc:
    raise newException(ACMEError, "Unable to parse JSON", exc)
  except CatchableError as exc:
    raise newException(
      ACMEError, "Unexpected error occurred while getting ACME server directory: ", exc
    )

proc newNonce(
    self: ref ACMEAccount
): Future[string] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let nonceURL = self.directory.getJSONField("newNonce").getStr
    let resp = await HttpClientRequestRef.get(self.session, nonceURL).get().send()
    return resp.headers.getString("replay-nonce")
  except HttpError:
    raise newException(ACMEError, "Failed to request new nonce from ACME server")

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
  except CatchableError as e:
    raise newException(ACMEError, "could not create JWT: " & e.msg)
  try:
    let response = await HttpClientRequestRef
    .post(
      self.session,
      url,
      body = $body,
      headers = [("Content-Type", "application/jose+json")],
    )
    .get()
    .send()
    return response
  except HttpError:
    raise newException(ACMEError, "Failed to send HTTP request to the ACME server")

proc register*(self: ref ACMEAccount) {.async: (raises: [ACMEError, CancelledError]).} =
  if self.kid.isSome:
    # already registered
    return

  let payload = %*{"termsOfServiceAgreed": true}

  let newAccountURL = self.directory.getJSONField("newAccount").getStr
  let response = await self.signedAcmeRequest(newAccountURL, payload, needsJwk = true)
  let jsonResponseBody = await response.getParsedResponseBody()
  if response.status != 201:
    raise newException(
      ACMEError, "Unable to register with ACME server: " & $jsonResponseBody
    )
  self.kid = Opt.some(response.headers.getString("location"))
  self.status = Opt.some(jsonResponseBody.getJSONField("status").getStr)

proc requestChallenge*(
    self: ref ACMEAccount, domains: seq[string]
): Future[(JsonNode, string, string)] {.async: (raises: [ACMEError, CancelledError]).} =
  # request challenge from ACME server
  var identifiers: seq[JsonNode]

  for domain in domains:
    identifiers.add(%*{"type": "dns", "value": domain})

  let orderPayload = %*{"identifiers": identifiers}
  let newOrderURL = self.directory.getJSONField("newOrder").getStr

  let challengeResponse = await self.signedAcmeRequest(newOrderURL, orderPayload)
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
    except CatchableError as e:
      raise newException(ACMEError, "failed to request challenge: " & e.msg)

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
    self: ref ACMEAccount, chalURL: string, retries: int = 5
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  let emptyPayload = newJObject()
  let completedResponse = await self.signedAcmeRequest(chalURL, emptyPayload)
  if completedResponse.status != 200:
    return false

  var completedResponseBody: JsonNode
  try:
    completedResponseBody =
      bytesToString(await completedResponse.getBodyBytes()).parseJson()
  except HttpError:
    raise newException(ACMEError, "Failed to connect to ACME server")
  except CatchableError as e:
    raise newException(
      ACMEError, "Unexpected error while signaling challenge completion: " & e.msg
    )

  let checkURL = completedResponseBody.getJSONField("url").getStr
  # check until acme server is done (poll validation)
  for _ in 0 .. retries:
    var checkResponseBody: JsonNode
    try:
      let checkResponse =
        await HttpClientRequestRef.get(self.session, checkURL).get().send()
      checkResponseBody = bytesToString(await checkResponse.getBodyBytes()).parseJson()
    except HttpError:
      raise newException(ACMEError, "Failed to connect to ACME server")
    except CatchableError as e:
      raise newException(
        ACMEError, "Unexpected error while signaling challenge completion: " & e.msg
      )
    case checkResponseBody.getJSONField("status").getStr
    of "pending":
      discard # try again
    of "valid":
      return true
    else:
      return false
    await sleepAsync(1.seconds)

  return false

proc finalizeCertificate*(
    self: ref ACMEAccount,
    domain: string,
    finalizeURL: string,
    orderURL: string,
    retries: int = 5,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  var certKey: cert_key_t
  var certCtx: cert_context_t
  var derCSR: ptr cert_buffer = nil

  # TODO: use secure method
  var randomCstring: cstring
  try:
    randomCstring = urandomToCString(256)
  except:
    raise newException(ACMEError, "Failed to generate random string")

  if cert_init_drbg(randomCstring, 256, certCtx.addr) != CERT_SUCCESS:
    raise newException(ACMEError, "Failed to initialize certCtx")
  if cert_generate_key(certCtx, certKey.addr) != CERT_SUCCESS:
    raise newException(ACMEError, "Failed to generate cert key")

  if cert_signing_req(domain.cstring, certKey, derCSR.addr) != CERT_SUCCESS:
    raise newException(ACMEError, "Failed to create CSR")

  let b64CSR = base64.encode(derCSR.toSeq, safe = true)
  let payload = %*{"csr": b64CSR}

  # send finalize request
  let finalizedResponse = await self.signedAcmeRequest(finalizeURL, payload)
  if finalizedResponse.status != 200:
    raise newException(ACMEError, "Failed to request cert finalization")

  # keep checking order until it's finalized
  var checkResponseBody: JsonNode
  for _ in 0 .. retries:
    let finalizedResponse = await self.signedAcmeRequest(finalizeURL, payload)
    try:
      let checkResponse =
        await HttpClientRequestRef.get(self.session, orderURL).get().send()
      checkResponseBody = bytesToString(await checkResponse.getBodyBytes()).parseJson()
    except CatchableError as e:
      raise newException(
        ACMEError, "Unexpected error while finalizing certificate: " & e.msg
      )

    let status = checkResponseBody.getJSONField("status").getStr
    case status
    of "valid":
      return true
    of "processing":
      discard # keep trying
    else:
      return false
    await sleepAsync(1.seconds)

  return false

proc downloadCertificate*(
    self: ref ACMEAccount, orderURL: string
): Future[(string, DateTime)] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let downloadResponse =
      await HttpClientRequestRef.get(self.session, orderURL).get().send()

    if downloadResponse.status != 200:
      raise newException(ACMEError, "Failed to download certificate")

    let certificateInfoBody =
      bytesToString(await downloadResponse.getBodyBytes()).parseJson()

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
  except CatchableError as e:
    raise newException(
      ACMEError, "Unexpected error while downloading certificate: " & e.msg
    )
