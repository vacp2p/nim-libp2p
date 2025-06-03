import options, base64, sequtils, serialization, json_serialization, tables
from times import DateTime, parse
import chronos/apps/http/httpclient, jwt, results, bearssl/pem
from std/json import
  JsonNode, `%*`, `%`, `[]`, `[]=`, `$`, parseJson, getStr, items, newJObject, to,
  JsonKindError

import ../utils
import ../../crypto/crypto
import ../../crypto/rsa
import ../../transports/tls/certificate_ffi
import ../../transports/tls/certificate

const
  LetsEncryptURL* = "https://acme-v02.api.letsencrypt.org"
  LetsEncryptURLStaging* = "https://acme-staging-v02.api.letsencrypt.org"
  Alg = "RS256"
  DefaultChalCompletedRetries = 10
  DefaultChalCompletedRetryTime = 1.seconds
  DefaultFinalizeRetries = 10
  DefaultFinalizeRetryTime = 1.seconds
  DefaultRandStringSize = 256

type Nonce = string
type Kid = string
type AccountStatus = string

type ACMEDirectory = object
  newNonce: string
  newOrder: string
  newAccount: string

type ACMEApi* = object
  directory: ACMEDirectory
  session*: HttpSessionRef
  acmeServerURL: string

type ACMEResponse = object
  body: JsonNode
  headers: HttpTable

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

type ACMEFinalizedResponse* = object

type ACMEOrderResponse* = object
  certificate: string
  expires: string

type ACMECertificateResponse* = object
  rawCertificate: string
  certificateExpiry: DateTime

template wrapSerialization(body: untyped): untyped =
  try:
    body
  except JsonKindError as exc:
    raise newException(ACMEError, "Failed to decode JSON", exc)
  except exceptions.KeyError as exc:
    raise newException(ACMEError, "Failed to decode JSON", exc)
  except ValueError as exc:
    raise newException(ACMEError, "Failed to decode JSON", exc)
  except HttpError as exc:
    raise newException(ACMEError, "Failed to connect to ACME server", exc)

proc new*(
    T: typedesc[ACMEApi], acmeServerURL: string = LetsEncryptURL
): Future[ACMEApi] {.async: (raises: [ACMEError, CancelledError]).} =
  let session = HttpSessionRef.new()
  let directory = wrapSerialization:
    (
      await (
        await HttpClientRequestRef.get(session, acmeServerURL & "/directory").get().send()
      ).getResponseBody()
    ).to(ACMEDirectory)

  return ACMEApi(session: session, directory: directory, acmeServerURL: acmeServerURL)

proc newNonce(
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

  # TODO: check if scheme is RSA
  let pubkey = key.pubkey.rsakey
  let nArray = @(getArray(pubkey.buffer, pubkey.key.n, pubkey.key.nlen))
  let eArray = @(getArray(pubkey.buffer, pubkey.key.e, pubkey.key.elen))
  let n = base64UrlEncode(nArray)
  let e = base64UrlEncode(eArray)

  let newNonce = await self.newNonce()
  if needsJwk:
    ACMERequestHeader(
      kind: ACMEJwkRequest,
      alg: Alg,
      typ: "JWT",
      nonce: newNonce,
      url: url,
      jwk: JWK(kty: "RSA", n: n, e: e),
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

proc signedAcmeRequest(
    self: ACMEApi,
    url: string,
    payload: auto,
    key: KeyPair,
    needsJwk: bool = false,
    kid: Opt[Kid] = Opt.none(Kid),
): Future[ACMEResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let acmeHeader = await self.acmeHeader(url, key, needsJwk, kid)
    var token = toJWT(%*{"header": acmeHeader, "claims": payload})
    let derPrivKey = key.seckey.rsakey.getBytes.get
    let pemPrivKey: string = pemEncode(derPrivKey, "PRIVATE KEY")
    token.sign(pemPrivKey)
    let rawResponse = await HttpClientRequestRef
    .post(
      self.session,
      url,
      body = $token.toFlattenedJson(),
      headers = [("Content-Type", "application/jose+json")],
    )
    .get()
    .send()
    return ACMEResponse(
      body: (await rawResponse.getResponseBody()), headers: rawResponse.headers
    )
  except HttpError as exc:
    raise newException(ACMEError, "Failed to send HTTP request to the ACME server", exc)
  except CatchableError as exc:
    raise newException(ACMEError, "Failed to create JWT", exc)

proc acmeRegister*(
    self: ACMEApi, key: KeyPair
): Future[ACMERegisterResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let registerRequest = ACMERegisterRequest(termsOfServiceAgreed: true)
  wrapSerialization:
    let acmeResponse = (
      await self.signedAcmeRequest(
        self.directory.newAccount, registerRequest, key, needsJwk = true
      )
    )
    ACMERegisterResponse(
      status: acmeResponse.body["status"].getStr,
      kid: acmeResponse.headers.getString("location"),
    )

proc requestChallenge*(
    self: ACMEApi, domains: seq[string], key: KeyPair, kid: Kid
): Future[ACMEChallengeResponseWrapper] {.async: (raises: [ACMEError, CancelledError]).} =
  # request challenge from ACME server
  let orderPayload = ACMEChallengeRequest(
    identifiers: domains.mapIt(ACMEChallengeIdentifier(`type`: "dns", value: it))
  )

  let (orderURL, challengeResponse) = wrapSerialization:
    let acmeResponse = (
      await self.signedAcmeRequest(
        self.directory.newOrder, orderPayload, key, kid = Opt.some(kid)
      )
    )
    (
      acmeResponse.headers.getString("location"),
      acmeResponse.body.to(ACMEChallengeResponse),
    )

  if challengeResponse.authorizations.len() == 0:
    raise newException(ACMEError, "Authorizations field is empty")

  # get challenges
  let authorizationsResponse = wrapSerialization:
    (
      await (
        await HttpClientRequestRef
        .get(self.session, challengeResponse.authorizations[0])
        .get()
        .send()
      ).getResponseBody()
    ).to(ACMEAuthorizationsResponse)

  let dns01 = authorizationsResponse.challenges.filterIt(it.`type` == "dns-01")[0]

  return ACMEChallengeResponseWrapper(
    finalizeURL: challengeResponse.finalize, orderURL: orderURL, dns01: dns01
  )

proc notifyChallengeCompleted*(
    self: ACMEApi,
    chalURL: string,
    key: KeyPair,
    kid: Kid,
    retries: int = DefaultChalCompletedRetries,
): Future[void] {.async: (raises: [ACMEError, CancelledError]).} =
  let emptyPayload = newJObject()

  let completedResponse = wrapSerialization:
    (await self.signedAcmeRequest(chalURL, emptyPayload, key, kid = Opt.some(kid))).body.to(
      ACMECompletedResponse
    )

  # check until acme server is done (poll validation)
  for _ in 0 .. retries:
    let rawResponse =
      try:
        await HttpClientRequestRef
        .get(self.session, completedResponse.checkURL)
        .get()
        .send()
      except HttpError as exc:
        raise newException(ACMEError, "Failed to connect to ACME server", exc)
    let checkResponse = wrapSerialization:
      (await rawResponse.getResponseBody()).to(ACMECheckResponse)

    case checkResponse.status
    of "pending":
      var retryAfter: Duration
      try:
        retryAfter = parseInt(rawResponse.headers.getString("Retry-After")).seconds
      except ValueError:
        retryAfter = DefaultChalCompletedRetryTime
      await sleepAsync(retryAfter) # try again after some delay
    of "valid":
      return
    else:
      raise newException(
        ACMEError,
        "Failed challenge completion: expected 'valid', got '" & checkResponse.status &
          "'",
      )

proc finalizeCertificate*(
    self: ACMEApi,
    domain: string,
    finalizeURL: string,
    orderURL: string,
    key: KeyPair,
    kid: Kid,
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

  # keep checking order until it's finalized
  var checkResponse: ACMECheckResponse
  for _ in 0 .. retries:
    let finalizedResponse = wrapSerialization:
      (await self.signedAcmeRequest(finalizeURL, payload, key, kid = Opt.some(kid))).body.to(
        ACMEFinalizedResponse
      )
    let rawResponse =
      try:
        await HttpClientRequestRef.get(self.session, orderURL).get().send()
      except CatchableError as exc:
        raise
          newException(ACMEError, "Unexpected error while finalizing certificate", exc)
    checkResponse = wrapSerialization:
      (await rawResponse.getResponseBody()).to(ACMECheckResponse)

    case checkResponse.status
    of "valid":
      return true
    of "processing":
      var retryAfter: Duration
      try:
        retryAfter = parseInt(rawResponse.headers.getString("Retry-After")).seconds
      except ValueError:
        retryAfter = DefaultFinalizeRetryTime
      await sleepAsync(retryAfter) # try again after some delay
    else:
      return false

  return false

proc downloadCertificate*(
    self: ACMEApi, orderURL: string
): Future[ACMECertificateResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  try:
    let orderResponse = wrapSerialization:
      (
        await (await HttpClientRequestRef.get(self.session, orderURL).get().send()).getResponseBody()
      ).to(ACMEOrderResponse)

    let certificateDownloadURL = orderResponse.certificate
    let certificateExpiry = parse(orderResponse.expires, "yyyy-MM-dd'T'HH:mm:ss'Z'")

    let certificateResponse =
      await HttpClientRequestRef.get(self.session, certificateDownloadURL).get().send()

    let rawCertificate = bytesToString(await certificateResponse.getBodyBytes())

    return ACMECertificateResponse(
      rawCertificate: rawCertificate, certificateExpiry: certificateExpiry
    )
  except HttpError as exc:
    raise newException(ACMEError, "Failed to connect to ACME server", exc)
  except ValueError as exc:
    raise newException(ACMEError, "Unexpected error while downloading certificate", exc)
