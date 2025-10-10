from ../../tests/helpers import checkTrackers
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

checkTrackers()
