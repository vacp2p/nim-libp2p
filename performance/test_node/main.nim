# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ./test_node
import ./utils
import chronos
import os

let scenarioName = getEnv("SCENARIO_NAME", "")

let transportType =
  case getEnv("TRANSPORT_TYPE", "TCP")
  of "QUIC": TransportType.QUIC
  else: TransportType.TCP

waitFor(baseTest(scenarioName, transportType))

# finalCheckTrackers is performed here instead in scenario tests to 
# avoid libp2p dependency thus keeping compile time short.
# Docker container will have libp2p dependency installed, making this
# functionality available here.
from ../../tests/tools/unittest import finalCheckTrackers
finalCheckTrackers()
