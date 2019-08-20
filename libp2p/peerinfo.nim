## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import peer, multiaddress

type PeerInfo* = ref object of RootRef
  peerId*: PeerID
  addrs*: seq[MultiAddress]
  protocols*: seq[string]
