# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import strformat
import strutils
import os
import osproc
import ./base_test/utils

proc setupOutputDirectory*(): string =
  let outputDir = getCurrentDir() / "output"
  createDir(outputDir)
  removeDir(outputDir)
  createDir(outputDir / "sync")
  return outputDir

proc setupDockerNetwork*(network: string) =
  let inspectOutput = execShellCommand(fmt"docker network inspect {network}")
  if "Error" in inspectOutput:
    echo execShellCommand(
      fmt"docker network create --attachable --driver bridge {network} > /dev/null"
    )

proc removeDockerNetwork*(network: string) =
  echo execShellCommand(fmt"docker network rm {network} > /dev/null")

proc startContainer*(
    i: int,
    hostnamePrefix: string,
    outputDir: string,
    network: string,
    transportType: string,
    preExecCmd: string = "",
    postExecCmd: string = "",
): string =
  let hostname = fmt"{hostnamePrefix}{i}"

  var envVars = fmt"-e NODE_ID={i}"
  envVars &= fmt" -e HOSTNAME_PREFIX={hostnamePrefix}"
  envVars &= fmt" -e TRANSPORT_TYPE='{transportType}'"

  if preExecCmd != "":
    envVars &= fmt" -e PRE_EXEC_CMD='{preExecCmd}'"
  if postExecCmd != "":
    envVars &= fmt" -e POST_EXEC_CMD='{postExecCmd}'"

  let containerId = execShellCommand(
    fmt"""docker run -d \
            --cap-add=NET_ADMIN \
            --name {hostname} \
            {envVars} \
            -v {outputDir}:/output \
            -v /var/run/docker.sock:/var/run/docker.sock \
            --hostname={hostname} \
            --network={network} \
            base"""
  )
  return containerId

proc streamContainerLogs*(containerIds: seq[string]) =
  for containerId in containerIds:
    discard startProcess(
      fmt"docker logs -f {containerId} > /dev/tty 2>&1",
      options = {poEvalCommand, poUsePath},
    )

proc waitForContainers*(containerIds: seq[string]) =
  for containerId in containerIds:
    discard execShellCommand(fmt"docker wait {containerId}")

proc removeContainers*(containerIds: seq[string]) =
  for containerId in containerIds:
    echo execShellCommand(fmt"docker rm -f {containerId}")

proc run*(transportType: string, preExecCmd: string = "", postExecCmd: string = "") =
  let outputDir = setupOutputDirectory()

  const network = "performance-test-network"
  setupDockerNetwork(network)

  var containerIds: seq[string]
  try:
    for i in 0 ..< 10:
      let hostname_prefix = "node-"
      let containerId = startContainer(
        i, hostname_prefix, outputDir, network, transportType, preExecCmd, postExecCmd
      )
      containerIds.add(containerId)

    streamContainerLogs(containerIds)
    waitForContainers(containerIds)
  finally:
    removeContainers(containerIds)
    removeDockerNetwork(network)
