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
  response*: AutonatV2Response
  dials*: int
  expectedDials: int
  finished*: Future[void]

proc new*(
    T: typedesc[AutonatV2ClientMock], response: AutonatV2Response, expectedDials: int
): T =
  return T(
    dials: 0,
    expectedDials: expectedDials,
    finished: newFuture[void](),
    response: response,
  )

method sendDialRequest*(
    self: AutonatV2ClientMock, pid: PeerId, testAddrs: seq[MultiAddress]
): Future[AutonatV2Response] {.
    async: (raises: [AutonatV2Error, CancelledError, DialFailedError, LPStreamError])
.} =
  self.dials += 1
  if self.dials == self.expectedDials:
    self.finished.complete()

  var ans = self.response

  ans.dialResp.addrIdx.withValue(addrIdx):
    ans.addrs = Opt.some(testAddrs[addrIdx])
  ans
