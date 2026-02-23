# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos
import ../../../../libp2p/[peerid, wire]
import ../../../../tests/interop/kad

const
  OurAddr = "/ip4/127.0.0.1/tcp/3131"
  PeerAddr = "/ip4/127.0.0.1/tcp/4141"
  PeerIdFile = "../rust-peer/peer.id"

when isMainModule:
  let ta = initTAddress(MultiAddress.init(PeerAddr).get()).get()
  if waitFor(waitForTCPServer(ta)):
    # ensure other peer has fully started
    waitFor(sleepAsync(5.seconds))

    let otherPeerId = PeerId.init(readFile(PeerIdFile)).get()
    let success = waitFor(kadInteropTest(OurAddr, PeerAddr, otherPeerId))
    if success:
      echo "Kademlia interop test was successful"
    else:
      quit("Kademlia interop test has failed", 1)
  else:
    quit("timeout waiting for service", 1)
