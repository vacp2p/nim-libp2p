# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

when defined(libp2p_agents_metrics):
  import results
  import strutils
  export results, split

  proc safeToLowerAscii*(s: string): Result[string, cstring] =
    try:
      ok(s.toLowerAscii())
    except CatchableError as e:
      let errMsg = "toLowerAscii failed: " & e.msg
      err(errMsg.cstring)

  const
    KnownLibP2PAgents* {.strdefine.} = "nim-libp2p"
    KnownLibP2PAgentsSeq* = KnownLibP2PAgents.safeToLowerAscii().tryGet().split(",")
