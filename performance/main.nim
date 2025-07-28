import chronos
import ./scenarios

waitFor(baseTest())
waitFor(latencyTest())
waitFor(packetLossTest())
waitFor(lowBandwithTest())
