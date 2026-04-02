# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import stew/endians2, chronos

type Delay* = uint16
  ## A mix-protocol forwarding delay in milliseconds, encoded as a big-endian
  ## uint16.

const NoDelay* = Delay(0)

proc toBytes*(d: Delay): seq[byte] {.inline.} =
  let bytes = d.toBytesBE()
  @[bytes[0], bytes[1]]

proc fromBytes*(T: typedesc[Delay], bytes: openArray[byte]): Delay {.inline.} =
  doAssert bytes.len == 2, "Delay.fromBytes expects exactly 2 bytes"
  uint16.fromBytesBE(bytes)

proc toDuration*(d: Delay): Duration =
  d.milliseconds
