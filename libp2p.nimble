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

import ospaths, strutils

task test, "Runs the test suite":
  for filename in listFiles("tests"):
    if filename.startsWith("tests" / "test") and filename.endsWith(".nim"):
      exec "nim c -r " & filename
      rmFile filename[0..^5]

