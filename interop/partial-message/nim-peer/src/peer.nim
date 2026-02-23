# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos
import ../../../../tests/interop/partial_message
import ../../../../libp2p/[multiaddress, peerid, wire]

# Note: ipv6 is intentionally used here as it ensures ipv6 interop with other implementation.
const
  OurAddr = "/ip4/0.0.0.0/tcp/3131"
  PeerAddr = "/ip4/0.0.0.0/tcp/4141"

when isMainModule:
  if paramCount() != 1:
    quit("Usage: nim r src/peer.nim <peerid>", 1)

  let ta = initTAddress(MultiAddress.init(PeerAddr).get()).get()
  if waitFor(waitForTCPServer(ta)):
    # ensure other peer has fully started
    waitFor(sleepAsync(1.seconds))

    let otherPeerId = PeerId.init(paramStr(1)).get()
    let success = waitFor(partialMessageInteropTest(OurAddr, PeerAddr, otherPeerId))
    if success:
      echo "Partial message introp test was successful"
    else:
      quit("Partial message introp test has failed", 1)
  else:
    quit("timeout waiting for service", 1)
