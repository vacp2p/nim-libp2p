import options, base64, sequtils, strutils, json, uri
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

type Authorization* = string
type Domain* = string
type Kid* = string
type Nonce* = string

type ACMEDirectory* = object
  newNonce*: string
  newOrder*: string
  newAccount*: string

type ACMEApi* = ref object of RootObj
  directory: Opt[ACMEDirectory]
  session: HttpSessionRef
  acmeServerURL*: Uri

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
  nonce: Nonce
  url: string
  case kind: ACMERequestType
  of ACMEJwkRequest:
    jwk: JWK
  of ACMEKidRequest:
    kid: Kid

type Email = string

type ACMERegisterRequest* = object
  termsOfServiceAgreed: bool
  contact: seq[Email]

type ACMEAccountStatus = enum
  valid = "valid"
  deactivated = "deactivated"
  revoked = "revoked"

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

type ACMEChallengeType* {.pure.} = enum
  dns01 = "dns-01"
  http01 = "http-01"
  tlsalpn01 = "tls-alpn-01"

type ACMEChallengeToken* = string

type ACMEChallenge* = object
  url*: string
  `type`*: ACMEChallengeType
  status*: ACMEChallengeStatus
  token*: ACMEChallengeToken

type ACMEChallengeIdentifier = object
  `type`: string
  value: string

type ACMEChallengeRequest = object
  identifiers: seq[ACMEChallengeIdentifier]

type ACMEChallengeResponseBody = object
  status: ACMEChallengeStatus
  authorizations: seq[Authorization]
  finalize: string

type ACMEChallengeResponse* = object
  status*: ACMEChallengeStatus
  authorizations*: seq[Authorization]
  finalize*: string
  order*: string

type ACMEChallengeResponseWrapper* = object
  finalize*: string
  order*: string
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
  self: ACMEApi, uri: Uri, payload: string
): Future[HTTPResponse] {.
  async: (raises: [ACMEError, HttpError, CancelledError]), base
.}

method get*(
  self: ACMEApi, uri: Uri
): Future[HTTPResponse] {.
  async: (raises: [ACMEError, HttpError, CancelledError]), base
.}

proc new*(
    T: typedesc[ACMEApi], acmeServerURL: Uri = parseUri(LetsEncryptURL)
): ACMEApi =
  let session = HttpSessionRef.new()

  ACMEApi(
    session: session, directory: Opt.none(ACMEDirectory), acmeServerURL: acmeServerURL
  )

proc getDirectory(
    self: ACMEApi
): Future[ACMEDirectory] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("getDirectory"):
    self.directory.valueOr:
      let acmeResponse = await self.get(self.acmeServerURL / "directory")
      let directory = acmeResponse.body.to(ACMEDirectory)
      self.directory = Opt.some(directory)
      directory

method requestNonce*(
    self: ACMEApi
): Future[Nonce] {.async: (raises: [ACMEError, CancelledError]), base.} =
  handleError("requestNonce"):
    let acmeResponse = await self.get(parseUri((await self.getDirectory()).newNonce))
    Nonce(acmeResponse.headers.keyOrError("Replay-Nonce"))

# TODO: save n and e in account so we don't have to recalculate every time
proc acmeHeader(
    self: ACMEApi, uri: Uri, key: KeyPair, needsJwk: bool, kid: Opt[Kid]
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
      url: $uri,
      jwk: JWK(kty: "RSA", n: base64UrlEncode(nArray), e: base64UrlEncode(eArray)),
    )
  else:
    ACMERequestHeader(
      kind: ACMEKidRequest,
      alg: Alg,
      typ: "JWT",
      nonce: newNonce,
      url: $uri,
      kid: kid.get(),
    )

method post*(
    self: ACMEApi, uri: Uri, payload: string
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

proc createSignedAcmeRequest(
    self: ACMEApi,
    uri: Uri,
    payload: auto,
    key: KeyPair,
    needsJwk: bool = false,
    kid: Opt[Kid] = Opt.none(Kid),
): Future[string] {.async: (raises: [ACMEError, CancelledError]).} =
  if key.pubkey.scheme != PKScheme.RSA or key.seckey.scheme != PKScheme.RSA:
    raise newException(ACMEError, "Unsupported signing key type")

  let acmeHeader = await self.acmeHeader(uri, key, needsJwk, kid)
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
      parseUri((await self.getDirectory()).newAccount),
      registerRequest,
      key,
      needsJwk = true,
    )
    let acmeResponse =
      await self.post(parseUri((await self.getDirectory()).newAccount), payload)
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
    let payload = await self.createSignedAcmeRequest(
      parseUri((await self.getDirectory()).newOrder),
      orderRequest,
      key,
      kid = Opt.some(kid),
    )
    let acmeResponse =
      await self.post(parseUri((await self.getDirectory()).newOrder), payload)
    let challengeResponseBody = acmeResponse.body.to(ACMEChallengeResponseBody)
    if challengeResponseBody.authorizations.len() == 0:
      raise newException(ACMEError, "Authorizations field is empty")
    ACMEChallengeResponse(
      status: challengeResponseBody.status,
      authorizations: challengeResponseBody.authorizations,
      finalize: challengeResponseBody.finalize,
      order: acmeResponse.headers.keyOrError("location"),
    )

proc requestAuthorizations*(
    self: ACMEApi, authorizations: seq[Authorization], key: KeyPair, kid: Kid
): Future[ACMEAuthorizationsResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("requestAuthorizations"):
    doAssert authorizations.len > 0
    let acmeResponse = await self.get(parseUri(authorizations[0]))
    acmeResponse.body.to(ACMEAuthorizationsResponse)

proc requestChallenge*(
    self: ACMEApi, domains: seq[Domain], key: KeyPair, kid: Kid
): Future[ACMEChallengeResponseWrapper] {.async: (raises: [ACMEError, CancelledError]).} =
  let challengeResponse = await self.requestNewOrder(domains, key, kid)
  if challengeResponse.status != ACMEChallengeStatus.pending:
    raise newException(
      ACMEError, "Invalid new challenge status: " & $challengeResponse.status
    )

  let authorizationsResponse =
    await self.requestAuthorizations(challengeResponse.authorizations, key, kid)
  if authorizationsResponse.challenges.len == 0:
    raise newException(ACMEError, "No challenges received")

  return ACMEChallengeResponseWrapper(
    finalize: challengeResponse.finalize,
    order: challengeResponse.order,
    dns01: authorizationsResponse.challenges.filterIt(
      it.`type` == ACMEChallengeType.dns01
    )[0],
      # getting the first element is safe since we checked that authorizationsResponse.challenges.len != 0
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

proc sendChallengeCompleted*(
    self: ACMEApi, chalURL: Uri, key: KeyPair, kid: Kid
): Future[ACMECompletedResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("sendChallengeCompleted (send notify)"):
    let payload =
      await self.createSignedAcmeRequest(chalURL, %*{}, key, kid = Opt.some(kid))
    let acmeResponse = await self.post(chalURL, payload)
    acmeResponse.body.to(ACMECompletedResponse)

proc checkChallengeCompleted*(
    self: ACMEApi,
    checkURL: Uri,
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
    chalURL: Uri,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultChalCompletedRetries,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  let completedResponse = await self.sendChallengeCompleted(chalURL, key, kid)
  # check until acme server is done (poll validation)
  return await self.checkChallengeCompleted(chalURL, key, kid, retries = retries)

proc requestFinalize*(
    self: ACMEApi, domain: Domain, finalize: Uri, key: KeyPair, kid: Kid
): Future[ACMEFinalizeResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let derCSR = createCSR(domain)
  let b64CSR = base64.encode(derCSR.toSeq, safe = true)

  handleError("requestFinalize"):
    let payload = await self.createSignedAcmeRequest(
      finalize, %*{"csr": b64CSR}, key, kid = Opt.some(kid)
    )
    let acmeResponse = await self.post(finalize, payload)
    # server responds with updated order response
    acmeResponse.body.to(ACMEFinalizeResponse)

proc checkCertFinalized*(
    self: ACMEApi,
    order: Uri,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultChalCompletedRetries,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  for i in 0 .. retries:
    let checkResponse = await self.requestCheck(order, ACMEOrderCheck, key, kid)
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
    finalize: Uri,
    order: Uri,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultFinalizeRetries,
): Future[bool] {.async: (raises: [ACMEError, CancelledError]).} =
  let finalizeResponse = await self.requestFinalize(domain, finalize, key, kid)
  # keep checking order until cert is valid (done)
  return await self.checkCertFinalized(order, key, kid, retries = retries)

proc requestGetOrder*(
    self: ACMEApi, order: Uri
): Future[ACMEOrderResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  handleError("requestGetOrder"):
    let acmeResponse = await self.get(order)
    acmeResponse.body.to(ACMEOrderResponse)

proc downloadCertificate*(
    self: ACMEApi, order: Uri
): Future[ACMECertificateResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let orderResponse = await self.requestGetOrder(order)

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
