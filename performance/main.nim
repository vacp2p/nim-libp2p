import chronos
import ./scenarios

waitFor(baseTest())
waitFor(latencyTest())
waitFor(packetLossTest())
waitFor(lowBandwithTest())
waitFor(packetReorderTest())
waitFor(burstLossTest())
waitFor(duplicationTest())
waitFor(corruptionTest())
waitFor(queueLimitTest())
waitFor(combinedTest())
