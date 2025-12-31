# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import net, os, chronos
import ../../../../tests/interop/autonatv2
import ../../../../libp2p/[multiaddress, peerid, wire]

# Note: ipv6 is intentionally used here as it ensures ipv6 interop with other implementation.
const
  OurAddr = "/ip6/::1/tcp/3030"
  PeerAddr = "/ip6/::1/tcp/4040"

when isMainModule:
  if paramCount() != 1:
    quit("Usage: nim r src/nim_peer.nim <peerid>", 1)

  let ta = initTAddress(MultiAddress.init(PeerAddr).get()).get()
  if waitFor(waitForTCPServer(ta)):
    # ensure other peer has fully started
    waitFor(sleepAsync(3.seconds))

    let otherPeerId = PeerId.init(paramStr(1)).get()
    let success = waitFor(autonatInteropTest(OurAddr, PeerAddr, otherPeerId))
    if success:
      echo "Autonatv2 introp test was successfull"
    else:
      quit("Autonatv2 introp test has failed", 1)
  else:
    quit("timeout waiting for service", 1)
