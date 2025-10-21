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
import ../tests/utils/async_tests
import ./runner

type NetworkScenario = object
  name: string
  setupCmd: string

const
  transportTypes = ["TCP", "QUIC"]
  tcCleanup = "tc qdisc del dev eth0 root"

  scenarios = [
    NetworkScenario(
      name: "Latency Test",
      setupCmd: "tc qdisc add dev eth0 root netem delay 100ms 20ms distribution normal",
    ),
    NetworkScenario(
      name: "Packet Loss Test", setupCmd: "tc qdisc add dev eth0 root netem loss 5%"
    ),
    NetworkScenario(
      name: "Low Bandwidth Test",
      setupCmd: "tc qdisc add dev eth0 root tbf rate 256kbit burst 8kbit limit 5000",
    ),
    NetworkScenario(
      name: "Packet Reorder Test",
      setupCmd: "tc qdisc add dev eth0 root netem delay 2ms reorder 15% 40%",
    ),
    NetworkScenario(
      name: "Burst Loss Test", setupCmd: "tc qdisc add dev eth0 root netem loss 8% 30%"
    ),
    NetworkScenario(
      name: "Duplication Test",
      setupCmd: "tc qdisc add dev eth0 root netem duplicate 2%",
    ),
    NetworkScenario(
      name: "Corruption Test", setupCmd: "tc qdisc add dev eth0 root netem corrupt 0.5%"
    ),
    NetworkScenario(
      name: "Queue Limit Test", setupCmd: "tc qdisc add dev eth0 root netem limit 5"
    ),
    NetworkScenario(
      name: "Combined Network Conditions Test",
      setupCmd:
        "tc qdisc add dev eth0 root handle 1:0 tbf rate 2mbit burst 32kbit limit 25000 && tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 100ms 20ms distribution normal loss 5% 20% reorder 10% 30% duplicate 0.5% corrupt 0.05% limit 20",
    ),
  ]

setupOutputDirectory()

suite "Network Reliability Tests":
  for transport in transportTypes:
    for scenario in scenarios:
      asyncTest fmt"{scenario.name} {transport}":
        run(
          scenario.name,
          transport,
          preExecCmd = scenario.setupCmd,
          postExecCmd = tcCleanup,
        )
