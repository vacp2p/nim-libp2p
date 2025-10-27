# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronicles
import strformat
import strutils
import os
import osproc

const
  NetworkName = "performance-test-network"
  NodeCount = 10
  HostnamePrefix = "node-"

proc getOutputDir*(): string =
  return getCurrentDir() / "output"

proc setupOutputDirectory*() =
  let outputDir = getOutputDir()
  removeDir(outputDir)
  createDir(outputDir / "sync")

proc execShellCommand*(cmd: string): string =
  try:
    let output = execProcess(
        "/bin/sh", args = ["-c", cmd], options = {poUsePath, poStdErrToStdOut}
      )
      .strip()
    debug "Shell command executed", cmd, output
    return output
  except OSError as e:
    raise newException(OSError, "Shell command failed: " & getCurrentExceptionMsg())

proc setupDockerNetwork*(network: string) =
  let inspectOutput = execShellCommand(fmt"docker network inspect {network}")
  if "Error" in inspectOutput:
    discard execShellCommand(
      fmt"docker network create --attachable --driver bridge {network} > /dev/null"
    )

proc removeDockerNetwork*(network: string) =
  discard execShellCommand(fmt"docker network rm {network} > /dev/null")

proc startContainer*(
    i: int,
    hostnamePrefix: string,
    outputDir: string,
    network: string,
    scenarioName: string,
    transportType: string,
    preExecCmd: string = "",
    postExecCmd: string = "",
): string =
  let hostname = fmt"{hostnamePrefix}{i}"

  var envVars = fmt"-e NODE_ID={i}"
  envVars &= fmt" -e HOSTNAME_PREFIX={hostnamePrefix}"
  envVars &= fmt" -e SCENARIO_NAME='{scenarioName}'"
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
            test_node"""
  )
  return containerId

proc streamContainerLogs*(containerIds: seq[string]) =
  for containerId in containerIds:
    discard startProcess(
      "docker",
      args = ["logs", "-f", containerId],
      options = {poParentStreams, poUsePath},
    )

proc waitForContainers*(containerIds: seq[string]) =
  for containerId in containerIds:
    discard execShellCommand(fmt"docker wait {containerId}")

proc removeContainers*(containerIds: seq[string]) =
  for containerId in containerIds:
    discard execShellCommand(fmt"docker rm -f {containerId}")

proc run*(
    scenarioName: string,
    transportType: string,
    preExecCmd: string = "",
    postExecCmd: string = "",
) =
  let outputDir = getOutputDir()

  setupDockerNetwork(NetworkName)

  var containerIds: seq[string]
  try:
    for i in 0 ..< NodeCount:
      let containerId = startContainer(
        i, HostnamePrefix, outputDir, NetworkName, scenarioName, transportType,
        preExecCmd, postExecCmd,
      )
      containerIds.add(containerId)

    streamContainerLogs(containerIds)
    waitForContainers(containerIds)
  finally:
    removeContainers(containerIds)
    removeDockerNetwork(NetworkName)
