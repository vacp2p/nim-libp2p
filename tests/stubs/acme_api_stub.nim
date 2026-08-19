# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

{.push raises: [].}

import json, uri
import chronos, chronos/apps/http/httpclient
import ../../libp2p/autotls/acme/[api, utils]

export api

const
  AccountURL = "https://acme.example/acct/1"
  OrderURL = "https://acme.example/order/1"
  FinalizeURL = "https://acme.example/finalize/1"
  AuthorizationsURL = "https://acme.example/authz/1"
  ChallengeURL = "https://acme.example/chal/1"

type ACMEApiStub* = ref object of ACMEApi
  ## Answers ACME requests from `mockedResponses`, recording what was requested.
  ## An empty queue refuses the request instead. While `stalls` is set the request
  ## stays pending, until it is cancelled.
  mockedResponses*: seq[HTTPResponse]
  requestedUris*: seq[Uri]
  stalls*: bool

proc new*(T: typedesc[ACMEApiStub]): ACMEApiStub =
  let directory = ACMEDirectory(
    newNonce: LetsEncryptURL & "/new-nonce",
    newOrder: LetsEncryptURL & "/new-order",
    newAccount: LetsEncryptURL & "/new-account",
  )
  ACMEApiStub(
    session: HttpSessionRef.new(),
    directory: Opt.some(directory),
    acmeServerURL: parseUri(LetsEncryptURL),
  )

proc scriptChallenge*(self: ACMEApiStub, token: string) =
  ## Queues the three responses `getChallenge` consumes, carrying `token` in the challenge.
  self.mockedResponses.add(
    HTTPResponse(
      body: %*{"status": "valid"}, headers: HttpTable.init(@[("location", AccountURL)])
    )
  )
  self.mockedResponses.add(
    HTTPResponse(
      body: %*{
        "status": "pending",
        "authorizations": [AuthorizationsURL],
        "finalize": FinalizeURL,
      },
      headers: HttpTable.init(@[("location", OrderURL)]),
    )
  )
  self.mockedResponses.add(
    HTTPResponse(
      body: %*{
        "challenges":
          [{"url": ChallengeURL, "type": "dns-01", "status": "pending", "token": token}]
      },
      headers: HttpTable.init(),
    )
  )

proc scriptCertificate*(self: ACMEApiStub, certificateURL: string, expires: string) =
  ## Queues the five responses `getCertificate` consumes, ending in an order whose
  ## certificate is served from `certificateURL`.
  for body in [
    %*{"url": ChallengeURL}, # sendChallengeCompleted
    %*{"status": "valid"}, # checkChallengeCompleted
    %*{"status": "valid"}, # requestFinalize
    %*{"status": "valid"}, # checkCertFinalized
  ]:
    self.mockedResponses.add(HTTPResponse(body: body, headers: HttpTable.init()))

  self.mockedResponses.add(
    HTTPResponse(
      body: %*{"certificate": certificateURL, "expires": expires},
      headers: HttpTable.init(),
    )
  )

proc respond(
    self: ACMEApiStub, uri: Uri
): Future[HTTPResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  self.requestedUris.add(uri)
  if self.stalls:
    await Future[void].Raising([CancelledError]).init("ACMEApiStub.stall")
  if self.mockedResponses.len == 0:
    raise newException(ACMEError, "ACMEApiStub refused " & $uri)

  let response = self.mockedResponses[0]
  self.mockedResponses.delete(0)
  response

method requestNonce*(
    self: ACMEApiStub
): Future[Nonce] {.async: (raises: [ACMEError, CancelledError]).} =
  $self.acmeServerURL & "/acme/1234"

method post*(
    self: ACMEApiStub, uri: Uri, payload: string
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  await self.respond(uri)

method get*(
    self: ACMEApiStub, uri: Uri
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  await self.respond(uri)
