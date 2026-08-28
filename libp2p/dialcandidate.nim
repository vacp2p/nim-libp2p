# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import multiaddress, peerid

type DialCandidate* = object
  ## One address a dial can attempt, with dnsaddr and DNS already resolved.
  address*: MultiAddress
  hostname*: string ## Host the address was reached under, for TLS and the Host header.
  peerId*: Opt[PeerId] ## Pinned by a dnsaddr record, otherwise the dialed peer's.
