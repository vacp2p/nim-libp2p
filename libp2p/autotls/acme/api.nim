import options, base64, sequtils, json
from times import DateTime, parse
import chronos/apps/http/httpclient, jwt, results, bearssl/pem

import ./utils
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
  session*: HttpSessionRef
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

  let newNonce = await self.newNonce()
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
  let acmeHeader = await self.acmeHeader(url, key, needsJwk, kid)
  handleError("createSignedAcmeRequest"):
    var token = toJWT(%*{"header": acmeHeader, "claims": payload})
    let derPrivKey = key.seckey.rsakey.getBytes.get
    let pemPrivKey: string = pemEncode(derPrivKey, "PRIVATE KEY")
    token.sign(pemPrivKey)
    $token.toFlattenedJson()

proc acmeRegister*(
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

proc requestChallenge*(
    self: ACMEApi, domains: seq[string], key: KeyPair, kid: Kid
): Future[ACMEChallengeResponseWrapper] {.async: (raises: [ACMEError, CancelledError]).} =
  # request challenge from ACME server
  let orderRequest = ACMEChallengeRequest(
    identifiers: domains.mapIt(ACMEChallengeIdentifier(`type`: "dns", value: it))
  )
  let (orderURL, challengeResponse) = handleError("requestChallenge (challenge)"):
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

  if challengeResponse.authorizations.len() == 0:
    raise newException(ACMEError, "Authorizations field is empty")

  # get challenges
  let authorizationsResponse = handleError("requestChallenge (authorizations)"):
    let rawResponse = await HttpClientRequestRef
    .get(self.session, challengeResponse.authorizations[0])
    .get()
    .send()
    let body = await rawResponse.getResponseBody()
    body.to(ACMEAuthorizationsResponse)

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
  let completedResponse = handleError("notifyChallengeCompleted (send notify)"):
    let payload =
      await self.createSignedAcmeRequest(chalURL, %*{}, key, kid = Opt.some(kid))
    let rawResponse = await HttpClientRequestRef
    .post(self.session, chalURL, body = payload, headers = ACMEHttpHeaders)
    .get()
    .send()
    let body = await rawResponse.getResponseBody()
    body.to(ACMECompletedResponse)

  # check until acme server is done (poll validation)
  for i in 0 .. retries:
    let (retryAfterHeader, checkResponse) = handleError(
      "notifyChallengeCompleted (check " & $i & ")"
    ):
      let rawResponse = await HttpClientRequestRef
      .get(self.session, completedResponse.checkURL)
      .get()
      .send()
      let body = await rawResponse.getResponseBody()
      (rawResponse.headers.getString("Retry-After"), body.to(ACMECheckResponse))

    case checkResponse.status
    of "pending":
      var retryAfter: Duration
      try:
        retryAfter = parseInt(retryAfterHeader).seconds
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

  # call finalize and keep checking order until cert is valid (done)
  handleError("finalizeCertificate (send finalize)"):
    let payload = await self.createSignedAcmeRequest(
      finalizeURL, %*{"csr": b64CSR}, key, kid = Opt.some(kid)
    )
    let rawResponse = await HttpClientRequestRef
    .post(self.session, finalizeURL, body = payload, headers = ACMEHttpHeaders)
    .get()
    .send()
    let body = await rawResponse.getResponseBody()
    let finalizeResponse = body.to(ACMEFinalizedResponse)

  handleError("finalizeCertificate (check finalized)"):
    var checkResponse: ACMECheckResponse
    for i in 0 .. retries:
      let rawResponse =
        await HttpClientRequestRef.get(self.session, orderURL).get().send()
      let body = await rawResponse.getResponseBody()
      let retryAfterHeader = rawResponse.headers.getString("Retry-After")
      checkResponse = body.to(ACMECheckResponse)

      case checkResponse.status
      of "valid":
        return true
      of "processing":
        var retryAfter: Duration
        try:
          retryAfter = parseInt(retryAfterHeader).seconds
        except ValueError:
          retryAfter = DefaultFinalizeRetryTime
        await sleepAsync(retryAfter) # try again after some delay
      else:
        return false

  return false

proc downloadCertificate*(
    self: ACMEApi, orderURL: string
): Future[ACMECertificateResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  let orderResponse = handleError("downloadCertificate (get download URL)"):
    let rawResponse =
      await HttpClientRequestRef.get(self.session, orderURL).get().send()
    let body = await rawResponse.getResponseBody()
    body.to(ACMEOrderResponse)

  handleError("downloadCertificate (download cert)"):
    let certificateDownloadURL = orderResponse.certificate
    let certificateExpiry = parse(orderResponse.expires, "yyyy-MM-dd'T'HH:mm:ss'Z'")

    let rawResponse =
      await HttpClientRequestRef.get(self.session, certificateDownloadURL).get().send()
    let rawBody = await rawResponse.getBodyBytes()

    ACMECertificateResponse(
      rawCertificate: bytesToString(rawBody), certificateExpiry: certificateExpiry
    )
