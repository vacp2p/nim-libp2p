# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

{.push raises: [].}

import uri
import chronos, chronos/apps/http/httpclient
import ../../libp2p/autotls/acme/api

export api

type ACMEApiStub* = ref object of ACMEApi
  ## Refuses every ACME request, recording what was requested.
  requestedUris*: seq[Uri]

proc new*(T: typedesc[ACMEApiStub]): ACMEApiStub =
  ACMEApiStub(session: HttpSessionRef.new(), acmeServerURL: parseUri(LetsEncryptURL))

proc refuse(
    self: ACMEApiStub, uri: Uri
): Future[HTTPResponse] {.async: (raises: [ACMEError, CancelledError]).} =
  self.requestedUris.add(uri)
  raise newException(ACMEError, "ACMEApiStub refused " & $uri)

method post*(
    self: ACMEApiStub, uri: Uri, payload: string
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  await self.refuse(uri)

method get*(
    self: ACMEApiStub, uri: Uri
): Future[HTTPResponse] {.async: (raises: [ACMEError, HttpError, CancelledError]).} =
  await self.refuse(uri)
