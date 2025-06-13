import chronos, chronos/apps/http/httpclient, json

import ./api, ./utils

export api

type MockACMEApi* = ref object of ACMEApi
  parent*: ACMEApi
  mockedHeaders*: HttpTable
  mockedBody*: JsonNode

proc new*(
    T: typedesc[MockACMEApi]
): Future[MockACMEApi] {.async: (raises: [ACMEError, CancelledError]).} =
  let directory = ACMEDirectory(
    newNonce: LetsEncryptURL & "/new-nonce",
    newOrder: LetsEncryptURL & "/new-order",
    newAccount: LetsEncryptURL & "/new-account",
  )
  MockACMEApi(
    session: HttpSessionRef.new(), directory: directory, acmeServerURL: LetsEncryptURL
  )

method requestNonce*(
    self: MockACMEApi
): Future[Nonce] {.async: (raises: [ACMEError, CancelledError]).} =
  return self.acmeServerURL & "/acme/1234"

method post*(
    self: MockACMEApi, url: string, payload: string
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  HTTPResponse(body: self.mockedBody, headers: self.mockedHeaders)

method get*(
    self: MockACMEApi, url: string
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  HTTPResponse(body: self.mockedBody, headers: self.mockedHeaders)
