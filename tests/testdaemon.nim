import unittest
import asyncdispatch2
import ../libp2p/daemon/daemonapi

proc identitySpawnTest(): Future[bool] {.async.} =
  var api = await newDaemonApi(sockpath = "/tmp/p2pd-1.sock")
  var data = await api.identity()
  await api.close()
  result = true

when isMainModule:
  suite "libp2p-daemon test suite":
    test "Simple spawn and get identity test":
      waitFor identitySpawnTest() == true
