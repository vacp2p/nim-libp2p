mode = ScriptMode.Verbose

packageName   = "libp2p"
version       = "0.0.2"
author        = "Status Research & Development GmbH"
description   = "LibP2P implementation"
license       = "MIT"
skipDirs      = @["tests", "examples", "Nim"]

requires "nim >= 1.2.0",
         "nimcrypto >= 0.4.1",
         "bearssl >= 0.1.4",
         "chronicles >= 0.7.2",
         "chronos >= 2.3.8",
         "metrics",
         "secp256k1",
         "stew"

proc runTest(filename: string, secure: string = "secio") =
  exec "nim c -r --opt:speed -d:debug --verbosity:0 --hints:off tests/" & filename
  rmFile "tests/" & filename.toExe

proc buildSample(filename: string) =
  exec "nim c --opt:speed --threads:on -d:debug --verbosity:0 --hints:off examples/" & filename
  rmFile "examples" & filename.toExe

task test, "Runs the test suite":
  runTest("testnative")
  runTest("testnative", "noise")
  runTest("testdaemon")
  runTest("testinterop")

task examples_build, "Build the samples":
  buildSample("directchat")
