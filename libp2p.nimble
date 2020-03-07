mode = ScriptMode.Verbose

packageName   = "libp2p"
version       = "0.0.2"
author        = "Status Research & Development GmbH"
description   = "LibP2P implementation"
license       = "MIT"
skipDirs      = @["tests", "examples", "Nim"]

requires "nim > 0.19.4",
         "secp256k1",
         "nimcrypto >= 0.4.1",
         "chronos >= 2.3.8",
         "bearssl >= 0.1.4",
         "chronicles >= 0.7.0",
         "stew"

proc runTest(filename: string) =
  exec "nim --opt:speed -d:release c -r tests/" & filename
  # rmFile "tests/" & filename

task test, "Runs the test suite":
  runTest "testnative"
  runTest "testdaemon"
  runTest "testinterop"
