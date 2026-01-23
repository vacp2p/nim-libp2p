# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

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
