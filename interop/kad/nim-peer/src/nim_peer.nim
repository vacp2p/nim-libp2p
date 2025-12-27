# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
import ../../../../libp2p/[peerid, wire]
import ../../../../tests/interop/kadTests

const
  PeerIdFile = "../rust-peer/peer.id"
  PeerAddr = "/ip4/127.0.0.1/tcp/4141"
  OurAddr = "/ip4/127.0.0.1/tcp/3131"

when isMainModule:
  let ta = initTAddress(MultiAddress.init(PeerAddr).get()).get()
  if waitFor(waitForTCPServer(ta)):
    # ensure other peer has fully started
    waitFor(sleepAsync(5.seconds))

    let otherPeerId = PeerId.init(readFile(PeerIdFile)).get()
    let success = waitFor(kadInteropTest(otherPeerId, PeerAddr, OurAddr))
    if success:
      echo "Kademlia introp test was successfull"
    else:
      quit("Kademlia introp test has failed", 1)
  else:
    quit("timeout waiting for service", 1)
