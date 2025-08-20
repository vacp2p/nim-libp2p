# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import results
import chronos, chronicles
import ../../../switch, ../../../multiaddress, ../../../peerid
import core

logScope:
  topics = "libp2p autonat v2"

type AutonatV2Client* = ref object of RootObj
  switch: Switch

proc dialRequest*(self: AutonatV2Client, addrs: seq[MultiAddress]): DialResponse =
  #   receive DialBack
  #   receive DialDataRequest
  #   send DialDataResponse
  #   receive DialResponse
  discard
