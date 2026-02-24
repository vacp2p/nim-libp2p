# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos, os
import ../../../../tests/interop/partial_message
import ../../../../libp2p/[multiaddress, peerid, wire]

# Note: ipv6 is intentionally used here as it ensures ipv6 interop with other implementation.
const
  OurAddr = "/ip6/::1/tcp/3131"
  PeerAddr = "/ip6/::1/tcp/4141"
  PeerIdFile = "/go-peer/peer.id"

when isMainModule:
  echo "Current directory: ", getCurrentDir()
  echo "Files and directories:"

  let ta = initTAddress(MultiAddress.init(PeerAddr).get()).get()
  if waitFor(waitForTCPServer(ta)):
    # ensure other peer has fully started
    waitFor(sleepAsync(1.seconds))

    for kind, path in walkDir(getCurrentDir() & PeerIdFile):
      echo " - ", path
    let otherPeerId = PeerId.init(readFile(PeerIdFile)).get()
    let success = waitFor(partialMessageInteropTest(OurAddr, PeerAddr, otherPeerId))
    if success:
      echo "Partial message interop test was successful"
    else:
      quit("Partial message interop test has failed", 1)
  else:
    quit("timeout waiting for service", 1)
