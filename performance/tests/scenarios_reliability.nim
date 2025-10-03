# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import strformat
import ../../tests/helpers
import ./base_test
import ./utils

suite "Network Reliability Tests":
  teardown:
    checkTrackers()

  asyncTest "Latency Test":
    const
      latency = 100
      jitter = 20

    discard execShellCommand(
      fmt"{enableTcCommand} netem delay {latency}ms {jitter}ms distribution normal"
    )
    let scenarioName = fmt"Latency {latency}ms {jitter}ms"
    await baseTest(scenarioName, TransportType.TCP)
    await baseTest(scenarioName, TransportType.QUIC)
    discard execShellCommand(disableTcCommand)

  asyncTest "Packet Loss Test":
    const packetLoss = 5

    discard execShellCommand(fmt"{enableTcCommand} netem loss {packetLoss}%")
    let scenarioName = fmt"Packet Loss {packetLoss}%"
    await baseTest(scenarioName, TransportType.TCP)
    await baseTest(scenarioName, TransportType.QUIC)
    discard execShellCommand(disableTcCommand)

  asyncTest "Low Bandwidth Test":
    const
      rate = "256kbit"
      burst = "8kbit"
      limit = "5000"

    discard execShellCommand(
      fmt"{enableTcCommand} tbf rate {rate} burst {burst} limit {limit}"
    )
    let scenarioName = fmt"Low Bandwidth rate {rate} burst {burst} limit {limit}"
    await baseTest(scenarioName, TransportType.TCP)
    await baseTest(scenarioName, TransportType.QUIC)
    discard execShellCommand(disableTcCommand)

  asyncTest "Packet Reorder Test":
    const
      reorderPercent = 15
      reorderCorr = 40
      delay = 2

    discard execShellCommand(
      fmt"{enableTcCommand} netem delay {delay}ms reorder {reorderPercent}% {reorderCorr}%"
    )
    let scenarioName =
      fmt"Packet Reorder {reorderPercent}% {reorderCorr}% with {delay}ms delay"
    await baseTest(scenarioName, TransportType.TCP)
    await baseTest(scenarioName, TransportType.QUIC)
    discard execShellCommand(disableTcCommand)

  asyncTest "Burst Loss Test":
    const
      lossPercent = 8
      lossCorr = 30

    discard
      execShellCommand(fmt"{enableTcCommand} netem loss {lossPercent}% {lossCorr}%")
    let scenarioName = fmt"Burst Loss {lossPercent}% {lossCorr}%"
    await baseTest(scenarioName, TransportType.TCP)
    await baseTest(scenarioName, TransportType.QUIC)
    discard execShellCommand(disableTcCommand)

  asyncTest "Duplication Test":
    const duplicatePercent = 2

    discard execShellCommand(fmt"{enableTcCommand} netem duplicate {duplicatePercent}%")
    let scenarioName = fmt"Duplication {duplicatePercent}%"
    await baseTest(scenarioName, TransportType.TCP)
    await baseTest(scenarioName, TransportType.QUIC)
    discard execShellCommand(disableTcCommand)

  asyncTest "Corruption Test":
    const corruptPercent = 0.5

    discard execShellCommand(fmt"{enableTcCommand} netem corrupt {corruptPercent}%")
    let scenarioName = fmt"Corruption {corruptPercent}%"
    await baseTest(scenarioName, TransportType.TCP)
    await baseTest(scenarioName, TransportType.QUIC)
    discard execShellCommand(disableTcCommand)

  asyncTest "Queue Limit Test":
    const queueLimit = 5

    discard execShellCommand(fmt"{enableTcCommand} netem limit {queueLimit}")
    let scenarioName = fmt"Queue Limit {queueLimit}"
    await baseTest(scenarioName, TransportType.TCP)
    await baseTest(scenarioName, TransportType.QUIC)
    discard execShellCommand(disableTcCommand)

  asyncTest "Combined Network Conditions Test":
    discard execShellCommand(
      "tc qdisc add dev eth0 root handle 1:0 tbf rate 2mbit burst 32kbit limit 25000"
    )
    discard execShellCommand(
      "tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 100ms 20ms distribution normal loss 5% 20% reorder 10% 30% duplicate 0.5% corrupt 0.05% limit 20"
    )
    let scenarioName = fmt"Combined Network Conditions"
    await baseTest(scenarioName, TransportType.TCP)
    await baseTest(scenarioName, TransportType.QUIC)
    discard execShellCommand(disableTcCommand)
