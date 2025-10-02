# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import ../tests/helpers
import ./tests/base_test
import ./tests/utils
import strformat
import strutils
import os
import osproc

suite "Performance Tests":
  teardown:
    checkTrackers()

  asyncTest "Base Test":
    # Clean up output
    # let outputDir = getCurrentDir() / "performance" / "output"
    let outputDir = getCurrentDir() / "output"
    createDir(outputDir)
    removeDir(outputDir)
    createDir(outputDir / "sync")

    const network = "performance-test-network"
    echo execShellCommand(fmt"docker network rm {network} > /dev/null")
    let inspectOutput = execShellCommand(fmt"docker network inspect {network}")
    if "Error" in inspectOutput:
      echo execShellCommand(
        fmt"docker network create --attachable --driver bridge {network} > /dev/null"
      )

    var containerIds: seq[string]
    try:
      for i in 0 ..< 10:
        let hostname_prefix = "node-"
        let hostname = fmt"{hostname_prefix}{i}"

        let containerId = execShellCommand(
          fmt"""docker run -d \
                  --cap-add=NET_ADMIN \
                  --name {hostname} \
                  -e NODE_ID={i} \
                  -e HOSTNAME_PREFIX={hostname_prefix} \
                  -v {outputDir}:/output \
                  -v /var/run/docker.sock:/var/run/docker.sock \
                  --hostname={hostname} \
                  --network={network} \
                  base"""
        )
        containerIds.add(containerId)

      for containerId in containerIds:
        discard startProcess(
          fmt"docker logs -f {containerId} > /dev/tty 2>&1",
          options = {poEvalCommand, poUsePath},
        )

      # Wait for all containers to finish
      for containerId in containerIds:
        discard execShellCommand(fmt"docker wait {containerId}")
    finally:
      for containerId in containerIds:
        echo execShellCommand(fmt"docker rm -f {containerId}")
