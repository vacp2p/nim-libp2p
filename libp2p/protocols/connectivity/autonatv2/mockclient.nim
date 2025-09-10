# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos
import ../../../peerid, ../../../multiaddress, ../../../switch
import ./client, ./types

type AutonatV2ClientMock* = ref object of AutonatV2Client
  responses*: seq[AutonatV2Response]
  dials: int
  finished*: Future[void]

proc new*(T: typedesc[AutonatV2ClientMock], responses: seq[AutonatV2Response]): T =
  return T(dials: 0, finished: newFuture[void](), responses: responses)

method sendDialRequest*(
    self: AutonatV2ClientMock, pid: PeerId, testAddrs: seq[MultiAddress]
): Future[AutonatV2Response] {.
    async: (raises: [AutonatV2Error, CancelledError, DialFailedError, LPStreamError])
.} =
  self.dials += 1
  if self.dials == self.responses.len:
    self.finished.complete()
  self.responses[self.dials - 1]
