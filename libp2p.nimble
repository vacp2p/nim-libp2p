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
         "chronicles >= 0.7.1",
         "stew"

proc runTest(filename: string) =
  exec "nim c -r --opt:speed -d:debug --verbosity:0 --hints:off tests/" & filename
  rmFile "tests/" & filename.toExe

task test, "Runs the test suite":
  runTest "testnative"
  runTest "testdaemon"
  runTest "testinterop"
