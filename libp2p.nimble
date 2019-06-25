mode = ScriptMode.Verbose

packageName   = "libp2p"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "LibP2P implementation"
license       = "MIT"
skipDirs      = @["tests", "examples", "Nim"]

requires "nim > 0.18.0",
         "nimcrypto >= 0.3.9",
         "chronos",
         "std_shims"

proc runTest(filename: string) =
  exec "nim c -r tests/" & filename
  rmFile "tests/" & filename

task test, "Runs the test suite":
  runTest "testnative"
  when not defined(windows):
    runTest "testdaemon"
