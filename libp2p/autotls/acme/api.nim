import options, base64, sequtils, json
from times import DateTime, parse
import chronos/apps/http/httpclient, jwt, results, bearssl/pem

import ./utils
import ../../crypto/crypto
import ../../crypto/rsa

const
  LetsEncryptURL* = "https://acme-v02.api.letsencrypt.org"
  LetsEncryptURLStaging* = "https://acme-staging-v02.api.letsencrypt.org"
  Alg = "RS256"
  DefaultChalCompletedRetries = 10
  DefaultChalCompletedRetryTime = 1.seconds
  DefaultFinalizeRetries = 10
  DefaultFinalizeRetryTime = 1.seconds
  DefaultRandStringSize = 256
  ACMEHttpHeaders = [("Content-Type", "application/jose+json")]

type Nonce = string
type Kid = string
type AccountStatus = string

type ACMEDirectory = object
  newNonce: string
  newOrder: string
  newAccount: string

type ACMEApi* = object
  directory: ACMEDirectory
  session: HttpSessionRef
  acmeServerURL: string

type JWK = object
  kty: string
  n: string
  e: string

# whether the request uses Kid or not
type ACMERequestType = enum
  ACMEJwkRequest
  ACMEKidRequest

type ACMERequestHeader = object
  alg: string
  typ: string
  nonce: string
  url: string
  case kind: ACMERequestType
  of ACMEJwkRequest:
    jwk: JWK
  of ACMEKidRequest:
    kid: Kid

type ACMERegisterRequest* = object
  termsOfServiceAgreed: bool
  contact: seq[string]

type ACMERegisterResponse* = object
  kid*: Kid
  status*: AccountStatus

type ACMEChallenge = object
  url*: string
  `type`*: string
  status*: string
  token*: string

type ACMEChallengeIdentifier = object
  `type`: string
  value: string

type ACMEChallengeRequest = object
  identifiers: seq[ACMEChallengeIdentifier]

type ACMEChallengeResponse* = object
  status: string
  authorizations: seq[string]
  finalize: string

type ACMEChallengeResponseWrapper* = object
  finalizeURL*: string
  orderURL*: string
  dns01*: ACMEChallenge

type ACMEAuthorizationsResponse* = object
  challenges: seq[ACMEChallenge]

type ACMECompletedResponse* = object
  checkURL: string

type ACMECheckResponse* = object
  status: string
  retryAfter: Duration

type ACMEFinalizedResponse* = object

type ACMEOrderResponse* = object
  certificate: string
  expires: string

type ACMECertificateResponse* = object
  rawCertificate: string
  certificateExpiry: DateTime

template handleError(msg: string, body: untyped): untyped =
  try:
    body
  # re-raise ACMEError
  except ACMEError as exc:
    raise (ref ACMEError)(exc)
  # re-raise CancelledError
  except CancelledError as exc:
    raise (ref CancelledError)(exc)
  except JsonKindError as exc:
    raise newException(ACMEError, msg & ": Failed to decode JSON", exc)
  except ValueError as exc:
    raise newException(ACMEError, msg & ": Failed to decode JSON", exc)
  except HttpError as exc:
    raise newException(ACMEError, msg & ": Failed to connect to ACME server", exc)
  except CatchableError as exc:
    raise newException(ACMEError, msg & ": Unexpected error", exc)

proc new*(
    T: typedesc[ACMEApi], acmeServerURL: string = LetsEncryptURL
): Future[ACMEApi] {.async: (raises: [ACMEError, CancelledError]).} =
  let session = HttpSessionRef.new()
  let directory = handleError("new API"):
    let rawResponse =
      await HttpClientRequestRef.get(session, acmeServerURL & "/directory").get().send()
    let body = await rawResponse.getResponseBody()
    body.to(ACMEDirectory)

  ACMEApi(session: session, directory: directory, acmeServerURL: acmeServerURL)

proc requestNonce(
    self: ACMEApi
): Future[Nonce] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let resp =
      await HttpClientRequestRef.get(self.session, self.directory.newNonce).get().send()
    return resp.headers.getString("Replay-Nonce")
  except HttpError as exc:
    raise newException(ACMEError, "Failed to request new nonce from ACME server", exc)

# TODO: save n and e in account so we don't have to recalculate every time
proc acmeHeader(
    self: ACMEApi, url: string, key: KeyPair, needsJwk: bool, kid: Opt[Kid]
): Future[ACMERequestHeader] {.async: (raises: [ACMEError, CancelledError]).} =
  if not needsJwk and kid.isNone:
    raise newException(ACMEError, "kid not set")

  let newNonce = await self.requestNonce()
  if needsJwk:
    # TODO: check if scheme is RSA
    let pubkey = key.pubkey.rsakey
    let nArray = @(getArray(pubkey.buffer, pubkey.key.n, pubkey.key.nlen))
    let eArray = @(getArray(pubkey.buffer, pubkey.key.e, pubkey.key.elen))
    ACMERequestHeader(
      kind: ACMEJwkRequest,
      alg: Alg,
      typ: "JWT",
      nonce: newNonce,
      url: url,
      jwk: JWK(kty: "RSA", n: base64UrlEncode(nArray), e: base64UrlEncode(eArray)),
    )
  else:
    ACMERequestHeader(
      kind: ACMEKidRequest,
      alg: Alg,
      typ: "JWT",
      nonce: newNonce,
      url: url,
      kid: kid.get(),
    )

proc createSignedAcmeRequest(
    self: ACMEApi,
    url: string,
    payload: auto,
    key: KeyPair,
    needsJwk: bool = false,
    kid: Opt[Kid] = Opt.none(Kid),
): Future[string] {.async: (raises: [ACMEError, CancelledError]).} =
  if key.pubkey.scheme != PKScheme.RSA or key.seckey.scheme != PKScheme.RSA:
    raise newException(ACMEError, "Unsupported signing key type")

  let acmeHeader = await self.acmeHeader(url, key, needsJwk, kid)
  handleError("createSignedAcmeRequest"):
    var token = toJWT(%*{"header": acmeHeader, "claims": payload})
    let derPrivKey = key.seckey.rsakey.getBytes.get
    let pemPrivKey: string = pemEncode(derPrivKey, "PRIVATE KEY")
    token.sign(pemPrivKey)
    $token.toFlattenedJson()

proc requestRegister*(
    self: ACMEApi, key: KeyPair
): Future[ACMERegisterResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let registerRequest = ACMERegisterRequest(termsOfServiceAgreed: true)
  handleError("acmeRegister"):
    let payload = await self.createSignedAcmeRequest(
      self.directory.newAccount, registerRequest, key, needsJwk = true
    )
    let rawResponse = await HttpClientRequestRef
    .post(
      self.session, self.directory.newAccount, body = payload, headers = ACMEHttpHeaders
    )
    .get()
    .send()
    let body = await rawResponse.getResponseBody()
    let headers = rawResponse.headers
    ACMERegisterResponse(
      status: body["status"].getStr, kid: headers.getString("location")
    )

proc requestNewOrder(
    self: ACMEApi, domains: seq[string], key: KeyPair, kid: Kid
): Future[(string, ACMEChallengeResponse)] {.
    async: (raises: [ACMEError, CancelledError])
.} =
  # request challenge from ACME server
  let orderRequest = ACMEChallengeRequest(
    identifiers: domains.mapIt(ACMEChallengeIdentifier(`type`: "dns", value: it))
  )
  handleError("requestNewOrder"):
    let payload = await self.createSignedAcmeRequest(
      self.directory.newOrder, orderRequest, key, kid = Opt.some(kid)
    )
    let rawResponse = await HttpClientRequestRef
    .post(
      self.session, self.directory.newOrder, body = payload, headers = ACMEHttpHeaders
    )
    .get()
    .send()
    let body = await rawResponse.getResponseBody()
    let headers = rawResponse.headers
    (headers.getString("location"), body.to(ACMEChallengeResponse))

proc requestAuthorizations(
    self: ACMEApi, authorizations: seq[string], key: KeyPair, kid: Kid
): Future[ACMEAuthorizationsResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("requestAuthorizations"):
    let rawResponse =
      await HttpClientRequestRef.get(self.session, authorizations[0]).get().send()
    let body = await rawResponse.getResponseBody()
    body.to(ACMEAuthorizationsResponse)

proc requestChallenge*(
    self: ACMEApi, domains: seq[string], key: KeyPair, kid: Kid
): Future[ACMEChallengeResponseWrapper] {.async: (raises: [ACMEError, CancelledError]).} =
  let (orderURL, challengeResponse) = await self.requestNewOrder(domains, key, kid)

  if challengeResponse.authorizations.len() == 0:
    raise newException(ACMEError, "Authorizations field is empty")

  let authorizationsResponse =
    await self.requestAuthorizations(challengeResponse.authorizations, key, kid)

  let dns01 = authorizationsResponse.challenges.filterIt(it.`type` == "dns-01")[0]

  return ACMEChallengeResponseWrapper(
    finalizeURL: challengeResponse.finalize, orderURL: orderURL, dns01: dns01
  )

proc requestCheck(
    self: ACMEApi, checkURL: string, key: KeyPair, kid: Kid
): Future[ACMECheckResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("requestCheck"):
    let rawResponse =
      await HttpClientRequestRef.get(self.session, checkURL).get().send()
    let body = await rawResponse.getResponseBody()
    let headers = rawResponse.headers
    let retryAfter =
      try:
        parseInt(rawResponse.headers.getString("Retry-After")).seconds
      except ValueError:
        DefaultChalCompletedRetryTime

    ACMECheckResponse(status: body["status"].getStr, retryAfter: retryAfter)

proc requestCompleted(
    self: ACMEApi, chalURL: string, key: KeyPair, kid: Kid
): Future[ACMECompletedResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("challengeCompleted (send notify)"):
    let payload =
      await self.createSignedAcmeRequest(chalURL, %*{}, key, kid = Opt.some(kid))
    let rawResponse = await HttpClientRequestRef
    .post(self.session, chalURL, body = payload, headers = ACMEHttpHeaders)
    .get()
    .send()
    let body = await rawResponse.getResponseBody()
    body.to(ACMECompletedResponse)

proc challengeCompleted*(
    self: ACMEApi,
    chalURL: string,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultChalCompletedRetries,
): Future[void] {.async: (raises: [ACMEError, CancelledError]).} =
  let completedResponse = await self.requestCompleted(chalURL, key, kid)
  # check until acme server is done (poll validation)
  for i in 0 .. retries:
    let checkResponse = await self.requestCheck(completedResponse.checkURL, key, kid)
    case checkResponse.status
    of "pending":
      await sleepAsync(checkResponse.retryAfter) # try again after some delay
    of "valid":
      return
    else:
      raise newException(
        ACMEError,
        "Failed challenge completion: expected 'valid', got '" & checkResponse.status &
          "'",
      )

proc requestFinalize*(
    self: ACMEApi, domain: string, finalizeURL: string, key: KeyPair, kid: Kid
): Future[ACMEFinalizedResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let derCSR = createCSR(domain)
  let b64CSR = base64.encode(derCSR.toSeq, safe = true)

  handleError("requestFinalize"):
    let payload = await self.createSignedAcmeRequest(
      finalizeURL, %*{"csr": b64CSR}, key, kid = Opt.some(kid)
    )
    let rawResponse = await HttpClientRequestRef
    .post(self.session, finalizeURL, body = payload, headers = ACMEHttpHeaders)
    .get()
    .send()
    let body = await rawResponse.getResponseBody()
    body.to(ACMEFinalizedResponse)

proc finalizeCertificate*(
    self: ACMEApi,
    domain: string,
    finalizeURL: string,
    orderURL: string,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultFinalizeRetries,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  # call finalize and keep checking order until cert is valid (done)
  let finalizeResponse = await self.requestFinalize(domain, finalizeURL, key, kid)

  handleError("finalizeCertificate (check finalized)"):
    var checkResponse: ACMECheckResponse
    for i in 0 .. retries:
      let checkResponse = await self.requestCheck(orderURL, key, kid)
      case checkResponse.status
      of "valid":
        return true
      of "processing":
        await sleepAsync(checkResponse.retryAfter) # try again after some delay
      else:
        return false

  return false

proc requestGetOrder*(
    self: ACMEApi, orderURL: string
): Future[ACMEOrderResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("requestGetOrder"):
    let rawResponse =
      await HttpClientRequestRef.get(self.session, orderURL).get().send()
    let body = await rawResponse.getResponseBody()
    body.to(ACMEOrderResponse)

proc downloadCertificate*(
    self: ACMEApi, orderURL: string
): Future[ACMECertificateResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let orderResponse = await self.requestGetOrder(orderURL)

  handleError("downloadCertificate"):
    let certificateDownloadURL = orderResponse.certificate
    let certificateExpiry = parse(orderResponse.expires, "yyyy-MM-dd'T'HH:mm:ss'Z'")

    let rawResponse =
      await HttpClientRequestRef.get(self.session, certificateDownloadURL).get().send()
    let rawBody = await rawResponse.getBodyBytes()

    ACMECertificateResponse(
      rawCertificate: bytesToString(rawBody), certificateExpiry: certificateExpiry
    )

proc close*(self: ACMEApi): Future[void] {.async: (raises: [CancelledError]).} =
  await self.session.closeWait()
