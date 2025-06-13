import options, base64, sequtils, strutils, json
from times import DateTime, parse
import chronos/apps/http/httpclient, jwt, results, bearssl/pem

import ./utils
import ../../crypto/crypto
import ../../crypto/rsa

export ACMEError

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

type Domain* = string
type Kid* = string
type Nonce* = string
type SignedACMERequest* = string

type ACMEDirectory* = object
  newNonce*: string
  newOrder*: string
  newAccount*: string

type ACMEApi* = ref object of RootObj
  directory: ACMEDirectory
  session: HttpSessionRef
  acmeServerURL*: string

type HTTPResponse* = object
  body*: JsonNode
  headers*: HttpTable

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

type ACMEAccountStatus = enum
  valid
  deactivated
  revoked

type ACMERegisterResponseBody = object
  status*: ACMEAccountStatus

type ACMERegisterResponse* = object
  kid*: Kid
  status*: ACMEAccountStatus

type ACMEChallengeStatus* {.pure.} = enum
  pending = "pending"
  processing = "processing"
  valid = "valid"
  invalid = "invalid"

type ACMEChallenge = object
  url*: string
  `type`*: string
  status*: ACMEChallengeStatus
  token*: string

type ACMEChallengeIdentifier = object
  `type`: string
  value: string

type ACMEChallengeRequest = object
  identifiers: seq[ACMEChallengeIdentifier]

type ACMEChallengeResponseBody = object
  status: ACMEChallengeStatus
  authorizations: seq[string]
  finalizeURL: string

type ACMEChallengeResponse* = object
  status*: ACMEChallengeStatus
  authorizations*: seq[string]
  finalizeURL*: string
  orderURL*: string

type ACMEChallengeResponseWrapper* = object
  finalizeURL*: string
  orderURL*: string
  dns01*: ACMEChallenge

type ACMEAuthorizationsResponse* = object
  challenges*: seq[ACMEChallenge]

type ACMECompletedResponse* = object
  checkURL: string

type ACMEOrderStatus* {.pure.} = enum
  pending = "pending"
  ready = "ready"
  processing = "processing"
  valid = "valid"
  invalid = "invalid"

type ACMECheckKind* = enum
  ACMEOrderCheck
  ACMEChallengeCheck

type ACMECheckResponse* = object
  case kind: ACMECheckKind
  of ACMEOrderCheck:
    orderStatus: ACMEOrderStatus
  of ACMEChallengeCheck:
    chalStatus: ACMEChallengeStatus
  retryAfter: Duration

type ACMEFinalizeResponse* = object
  status: ACMEOrderStatus

type ACMEOrderResponse* = object
  certificate: string
  expires: string

type ACMECertificateResponse* = object
  rawCertificate: string
  certificateExpiry: DateTime

template handleError*(msg: string, body: untyped): untyped =
  try:
    body
  except ACMEError as exc:
    raise exc
  except CancelledError as exc:
    raise exc
  except JsonKindError as exc:
    raise newException(ACMEError, msg & ": Failed to decode JSON", exc)
  except ValueError as exc:
    raise newException(ACMEError, msg & ": Failed to decode JSON", exc)
  except HttpError as exc:
    raise newException(ACMEError, msg & ": Failed to connect to ACME server", exc)
  except CatchableError as exc:
    raise newException(ACMEError, msg & ": Unexpected error", exc)

method post*(
  self: ACMEApi, url: Uri, payload: SignedACMERequest
): Future[HTTPResponse] {.
  async: (raises: [ACMEError, HttpError, CancelledError]), base
.}

method get*(
  self: ACMEApi, url: Uri
): Future[HTTPResponse] {.
  async: (raises: [ACMEError, HttpError, CancelledError]), base
.}

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

method requestNonce*(
    self: ACMEApi
): Future[Nonce] {.async: (raises: [ACMEError, CancelledError]), base.} =
  handleError("requestNonce"):
    let acmeResponse = await self.get(self.directory.newNonce)
    Nonce(acmeResponse.headers.keyOrError("Replay-Nonce"))

# TODO: save n and e in account so we don't have to recalculate every time
proc acmeHeader(
    self: ACMEApi, url: string, key: KeyPair, needsJwk: bool, kid: Opt[Kid]
): Future[ACMERequestHeader] {.async: (raises: [ACMEError, CancelledError]).} =
  if not needsJwk and kid.isNone:
    raise newException(ACMEError, "kid not set")

  if key.pubkey.scheme != PKScheme.RSA or key.seckey.scheme != PKScheme.RSA:
    raise newException(ACMEError, "Unsupported signing key type")

  let newNonce = await self.requestNonce()
  if needsJwk:
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

method post*(
    self: ACMEApi, uri: Uri, payload: SignedACMERequest
): Future[HTTPResponse] {.
    async: (raises: [ACMEError, HttpError, CancelledError]), base
.} =
  let rawResponse = await HttpClientRequestRef
  .post(self.session, $uri, body = payload, headers = ACMEHttpHeaders)
  .get()
  .send()
  let body = await rawResponse.getResponseBody()
  HTTPResponse(body: body, headers: rawResponse.headers)

method get*(
    self: ACMEApi, uri: Uri
): Future[HTTPResponse] {.
    async: (raises: [ACMEError, HttpError, CancelledError]), base
.} =
  let rawResponse = await HttpClientRequestRef.get(self.session, $uri).get().send()
  let body = await rawResponse.getResponseBody()
  HTTPResponse(body: body, headers: rawResponse.headers)

proc createSignedACMERequest(
    self: ACMEApi,
    uri: Uri,
    payload: auto,
    key: KeyPair,
    needsJwk: bool = false,
    kid: Opt[Kid] = Opt.none(Kid),
): Future[SignedACMERequest] {.async: (raises: [ACMEError, CancelledError]).} =
  if key.pubkey.scheme != PKScheme.RSA or key.seckey.scheme != PKScheme.RSA:
    raise newException(ACMEError, "Unsupported signing key type")

  let acmeHeader = await self.acmeHeader(url, key, needsJwk, kid)
  handleError("createSignedACMERequest"):
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
    let payload = await self.createSignedACMERequest(
      self.directory.newAccount, registerRequest, key, needsJwk = true
    )
    let acmeResponse = await self.post(self.directory.newAccount, payload)
    let acmeResponseBody = acmeResponse.body.to(ACMERegisterResponseBody)

    ACMERegisterResponse(
      status: acmeResponseBody.status, kid: acmeResponse.headers.keyOrError("location")
    )

proc requestNewOrder*(
    self: ACMEApi, domains: seq[Domain], key: KeyPair, kid: Kid
): Future[ACMEChallengeResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  # request challenge from ACME server
  let orderRequest = ACMEChallengeRequest(
    identifiers: domains.mapIt(ACMEChallengeIdentifier(`type`: "dns", value: it))
  )
  handleError("requestNewOrder"):
    let payload = await self.createSignedACMERequest(
      self.directory.newOrder, orderRequest, key, kid = Opt.some(kid)
    )
    let acmeResponse = await self.post(self.directory.newOrder, payload)

    let challengeResponseBody = acmeResponse.body.to(ACMEChallengeResponseBody)
    if challengeResponseBody.authorizations.len() == 0:
      raise newException(ACMEError, "Authorizations field is empty")
    ACMEChallengeResponse(
      status: challengeResponseBody.status,
      authorizations: challengeResponseBody.authorizations,
      finalizeURL: challengeResponseBody.finalize,
      orderURL: acmeResponse.headers.keyOrError("location"),
    )

proc requestAuthorizations*(
    self: ACMEApi, authorizations: seq[string], key: KeyPair, kid: Kid
): Future[ACMEAuthorizationsResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("requestAuthorizations"):
    doAssert authorizations.len > 0
    let acmeResponse = await self.get(authorizations[0])
    acmeResponse.body.to(ACMEAuthorizationsResponse)

proc requestChallenge*(
    self: ACMEApi, domains: seq[Domain], key: KeyPair, kid: Kid
): Future[ACMEChallengeResponseWrapper] {.async: (raises: [ACMEError, CancelledError]).} =
  let challengeResponse = await self.requestNewOrder(domains, key, kid)

  let authorizationsResponse =
    await self.requestAuthorizations(challengeResponse.authorizations, key, kid)

  return ACMEChallengeResponseWrapper(
    finalizeURL: challengeResponse.finalize,
    orderURL: challengeResponse.orderURL,
    dns01: authorizationsResponse.challenges.filterIt(it.`type` == "dns-01")[0],
  )

proc requestCheck*(
    self: ACMEApi, checkURL: Uri, checkKind: ACMECheckKind, key: KeyPair, kid: Kid
): Future[ACMECheckResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("requestCheck"):
    let acmeResponse = await self.get(checkURL)
    let retryAfter =
      try:
        parseInt(acmeResponse.headers.keyOrError("Retry-After")).seconds
      except ValueError:
        DefaultChalCompletedRetryTime

    case checkKind
    of ACMEOrderCheck:
      try:
        ACMECheckResponse(
          kind: checkKind,
          orderStatus: parseEnum[ACMEOrderStatus](acmeResponse.body["status"].getStr),
          retryAfter: retryAfter,
        )
      except ValueError:
        raise newException(
          ACMEError, "Invalid order status: " & acmeResponse.body["status"].getStr
        )
    of ACMEChallengeCheck:
      try:
        ACMECheckResponse(
          kind: checkKind,
          chalStatus: parseEnum[ACMEChallengeStatus](acmeResponse.body["status"].getStr),
          retryAfter: retryAfter,
        )
      except ValueError:
        raise newException(
          ACMEError, "Invalid order status: " & acmeResponse.body["status"].getStr
        )

proc requestCompleted*(
    self: ACMEApi, chalURL: string, key: KeyPair, kid: Kid
): Future[ACMECompletedResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("requestCompleted (send notify)"):
    let payload =
      await self.createSignedACMERequest(chalURL, %*{}, key, kid = Opt.some(kid))
    let acmeResponse = await self.post(chalURL, payload)
    acmeResponse.body.to(ACMECompletedResponse)

proc checkChallengeCompleted*(
    self: ACMEApi,
    checkURL: string,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultChalCompletedRetries,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  for i in 0 .. retries:
    let checkResponse = await self.requestCheck(checkURL, ACMEChallengeCheck, key, kid)
    case checkResponse.chalStatus
    of ACMEChallengeStatus.pending:
      await sleepAsync(checkResponse.retryAfter) # try again after some delay
    of ACMEChallengeStatus.valid:
      return true
    else:
      raise newException(
        ACMEError,
        "Failed challenge completion: expected 'valid', got '" &
          $checkResponse.chalStatus & "'",
      )
  return false

proc completeChallenge*(
    self: ACMEApi,
    chalURL: string,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultChalCompletedRetries,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  let completedResponse = await self.requestCompleted(chalURL, key, kid)
  # check until acme server is done (poll validation)
  return await self.checkChallengeCompleted(chalURL, key, kid, retries = retries)

proc requestFinalize*(
    self: ACMEApi, domain: Domain, finalizeURL: uri, key: KeyPair, kid: Kid
): Future[ACMEFinalizeResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let derCSR = createCSR(domain)
  let b64CSR = base64.encode(derCSR.toSeq, safe = true)

  handleError("requestFinalize"):
    let payload = await self.createSignedACMERequest(
      finalizeURL, %*{"csr": b64CSR}, key, kid = Opt.some(kid)
    )
    let acmeResponse = await self.post(finalizeURL, payload)
    # server responds with updated order response
    acmeResponse.body.to(ACMEFinalizeResponse)

proc checkCertFinalized*(
    self: ACMEApi,
    orderURL: Uri,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultChalCompletedRetries,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  for i in 0 .. retries:
    let checkResponse = await self.requestCheck(orderURL, ACMEOrderCheck, key, kid)
    case checkResponse.orderStatus
    of ACMEOrderStatus.valid:
      return true
    of ACMEOrderStatus.processing:
      await sleepAsync(checkResponse.retryAfter) # try again after some delay
    else:
      raise newException(
        ACMEError,
        "Failed certificate finalization: expected 'valid', got '" &
          $checkResponse.orderStatus & "'",
      )
      return false

  return false

proc certificateFinalized*(
    self: ACMEApi,
    domain: Domain,
    finalizeURL: Uri,
    orderURL: Uri,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultFinalizeRetries,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  let finalizeResponse = await self.requestFinalize(domain, finalizeURL, key, kid)
  # keep checking order until cert is valid (done)
  return await self.checkCertFinalized(orderURL, key, kid, retries = retries)

proc requestGetOrder*(
    self: ACMEApi, orderURL: Uri
): Future[ACMEOrderResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("requestGetOrder"):
    let acmeResponse = await self.get($orderURL)
    acmeResponse.body.to(ACMEOrderResponse)

proc downloadCertificate*(
    self: ACMEApi, orderURL: Uri
): Future[ACMECertificateResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let orderResponse = await self.requestGetOrder($orderURL)

  handleError("downloadCertificate"):
    let rawResponse = await HttpClientRequestRef
    .get(self.session, orderResponse.certificate)
    .get()
    .send()
    ACMECertificateResponse(
      rawCertificate: bytesToString(await rawResponse.getBodyBytes()),
      certificateExpiry: parse(orderResponse.expires, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
    )

proc close*(self: ACMEApi): Future[void] {.async: (raises: [CancelledError]).} =
  await self.session.closeWait()
