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
         "stew >= 0.1.0"

proc runTest(filename: string, verify: bool = true, sign: bool = true) =
  var excstr: string = "nim c -r --opt:speed -d:debug --verbosity:0 --hints:off"
  excstr.add(" ")
  excstr.add("-d:libp2p_pubsub_sign=" & $sign)
  excstr.add(" ")
  excstr.add("-d:libp2p_pubsub_verify=" & $verify)
  excstr.add(" ")
  excstr.add("tests/" & filename)
  exec excstr
  rmFile "tests/" & filename.toExe

proc buildSample(filename: string) =
  exec "nim c --opt:speed --threads:on -d:debug --verbosity:0 --hints:off examples/" & filename
  rmFile "examples" & filename.toExe

task testnative, "Runs libp2p native tests":
  runTest("testnative")

task testdaemon, "Runs daemon tests":
  runTest("testdaemon")

task testinterop, "Runs interop tests":
  runTest("testinterop")

task testpubsub, "Runs pubsub tests":
  runTest("pubsub/testpubsub")
  runTest("pubsub/testpubsub", sign = false, verify = false)

task test, "Runs the test suite":
  exec "nimble testnative"
  exec "nimble testpubsub"
  exec "nimble testdaemon"
  exec "nimble testinterop"

task examples_build, "Build the samples":
  buildSample("directchat")
