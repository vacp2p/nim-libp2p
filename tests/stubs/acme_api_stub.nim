# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

{.push raises: [].}

import uri
import chronos, chronos/apps/http/httpclient
import ../../libp2p/[autotls/acme/api, utils/opt]

export api

type ACMEApiStub* = ref object of ACMEApi
  ## Refuses every ACME request, recording what was requested.
  stalls*: bool
  requestedUris*: seq[Uri]

proc new*(T: typedesc[ACMEApiStub]): ACMEApiStub =
  ACMEApiStub(
    session: HttpSessionRef.new(),
    directory: Opt.some(
      ACMEDirectory(
        newNonce: LetsEncryptURL & "/new-nonce",
        newOrder: LetsEncryptURL & "/new-order",
        newAccount: LetsEncryptURL & "/new-account",
      )
    ),
    acmeServerURL: parseUri(LetsEncryptURL),
  )

method requestNonce*(
    self: ACMEApiStub
): Future[Nonce] {.async: (raises: [ACMEError, CancelledError]).} =
  Nonce($self.acmeServerURL & "/acme/1234")

proc stallUntilCancelled(self: ACMEApiStub) {.async: (raises: [CancelledError]).} =
  ## A request that only ends when the caller gives up on it.
  await Future[void].Raising([CancelledError]).init("ACMEApiStub.request")

proc refuse(
    self: ACMEApiStub, uri: Uri
): Future[HTTPResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  self.requestedUris.add(uri)
  if self.stalls:
    await self.stallUntilCancelled()
  raise newException(ACMEError, "ACMEApiStub refused " & $uri)

method post*(
    self: ACMEApiStub, uri: Uri, payload: string
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  await self.refuse(uri)

method get*(
    self: ACMEApiStub, uri: Uri
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  await self.refuse(uri)
