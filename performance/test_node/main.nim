import ./test_node
import ./utils
import chronos
import os

let transportType =
  case getEnv("TRANSPORT_TYPE", "TCP")
  of "QUIC": TransportType.QUIC
  else: TransportType.TCP

waitFor(baseTest("Base Test", transportType))
