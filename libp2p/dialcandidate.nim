# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import multiaddress, peerid

type DialCandidate* = object
  ## One address a dial can attempt, with dnsaddr and DNS already resolved.
  address*: MultiAddress
  hostname*: string
    ## Name the address was resolved from, empty when it is a wire address.
  peerId*: Opt[PeerId] ## Pinned by a dnsaddr record, otherwise the dialed peer's.
