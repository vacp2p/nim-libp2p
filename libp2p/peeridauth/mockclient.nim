# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos, chronos/apps/http/httpclient
import ../crypto/crypto

import ./client

export client

type MockPeerIDAuthClient* = ref object of PeerIDAuthClient
  mockedStatus*: int
  mockedHeaders*: HttpTable
  mockedBody*: seq[byte]

proc new*(
    T: typedesc[MockPeerIDAuthClient], rng: ref HmacDrbgContext
): MockPeerIDAuthClient {.raises: [PeerIDAuthError].} =
  MockPeerIDAuthClient(session: HttpSessionRef.new(), rng: rng)

method post*(
    self: MockPeerIDAuthClient, uri: string, payload: string, authHeader: string
): Future[PeerIDAuthResponse] {.async: (raises: [HttpError, CancelledError]).} =
  PeerIDAuthResponse(
    status: self.mockedStatus, headers: self.mockedHeaders, body: self.mockedBody
  )

method get*(
    self: MockPeerIDAuthClient, uri: string
): Future[PeerIDAuthResponse] {.async: (raises: [HttpError, CancelledError]).} =
  PeerIDAuthResponse(
    status: self.mockedStatus, headers: self.mockedHeaders, body: self.mockedBody
  )
