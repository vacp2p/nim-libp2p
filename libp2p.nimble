mode = ScriptMode.Verbose

packageName   = "libp2p"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "LibP2P implementation"
license       = "MIT"
skipDirs      = @["tests", "examples", "Nim"]

requires "nim > 0.18.0",
         "nimcrypto >= 0.3.9",
         "chronos"

import ospaths, strutils, distros

task test, "Runs the test suite":
  exec "nim c -r " & ("tests" / "testnative.nim")
  if not detectOs(Windows):
    exec "nim c -r " & ("tests" / "testdaemon.nim")
