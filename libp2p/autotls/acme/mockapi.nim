import uri
import chronos, chronos/apps/http/httpclient, json
import ./api, ./utils

export api

type MockACMEApi* = ref object of ACMEApi
  mockedResponses*: seq[HTTPResponse]

proc new*(
    T: typedesc[MockACMEApi]
): Future[T] {.async: (raises: [ACMEError, CancelledError]).} =
  let directory = ACMEDirectory(
    newNonce: LetsEncryptURL & "/new-nonce",
    newOrder: LetsEncryptURL & "/new-order",
    newAccount: LetsEncryptURL & "/new-account",
  )
  MockACMEApi(
    session: HttpSessionRef.new(),
    directory: Opt.some(directory),
    acmeServerURL: parseUri(LetsEncryptURL),
  )

method requestNonce*(
    self: MockACMEApi
): Future[Nonce] {.async: (raises: [ACMEError, CancelledError]).} =
  return $self.acmeServerURL & "/acme/1234"

method post*(
    self: MockACMEApi, uri: Uri, payload: string
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  result = self.mockedResponses[0]
  self.mockedResponses.delete(0)

method get*(
    self: MockACMEApi, uri: Uri
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  result = self.mockedResponses[0]
  self.mockedResponses.delete(0)
