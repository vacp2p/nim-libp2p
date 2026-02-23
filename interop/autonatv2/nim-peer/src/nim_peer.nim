# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import net, os, chronos
import ../../../../tests/interop/autonatv2
import ../../../../libp2p/[multiaddress, peerid, wire]

# Note: ipv6 is intentionally used here as it ensures ipv6 interop with other implementation.
const
  OurAddr = "/ip6/::1/tcp/3030"
  PeerAddr = "/ip6/::1/tcp/4040"

when isMainModule:
  if paramCount() != 1:
    quit("Aborting. Peer ID not specified", 1)

  let ta = initTAddress(MultiAddress.init(PeerAddr).get()).get()
  if waitFor(waitForTCPServer(ta)):
    # ensure other peer has fully started
    waitFor(sleepAsync(3.seconds))

    let otherPeerId = PeerId.init(paramStr(1)).get()
    let success = waitFor(autonatInteropTest(OurAddr, PeerAddr, otherPeerId))
    if success:
      echo "Autonatv2 interop test was successful"
    else:
      quit("Autonatv2 interop test has failed", 1)
  else:
    quit("timeout waiting for service", 1)
