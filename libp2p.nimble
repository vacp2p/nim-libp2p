mode = ScriptMode.Verbose

packageName   = "libp2p"
version       = "0.0.2"
author        = "Status Research & Development GmbH"
description   = "LibP2P implementation"
license       = "MIT"
skipDirs      = @["tests", "examples", "Nim", "tools", "scripts", "docs"]

requires "nim >= 1.2.0",
         "nimcrypto >= 0.4.1",
         "https://github.com/ba0f3/dnsclient.nim == 0.1.0",
         "bearssl >= 0.1.4",
         "chronicles#ba2817f1",
         "chronos >= 3.0.6",
         "metrics",
         "secp256k1",
         "stew#head",
         "websock"

proc runTest(filename: string, verify: bool = true, sign: bool = true,
             moreoptions: string = "") =
  let env_nimflags = getEnv("NIMFLAGS")
  var excstr = "nim c --opt:speed -d:debug -d:libp2p_agents_metrics -d:libp2p_protobuf_metrics -d:libp2p_network_protocols_metrics --verbosity:0 --hints:off --styleCheck:usages --styleCheck:hint " & env_nimflags
  excstr.add(" --warning[CaseTransition]:off --warning[ObservableStores]:off --warning[LockLevel]:off")
  excstr.add(" -d:libp2p_pubsub_sign=" & $sign)
  excstr.add(" -d:libp2p_pubsub_verify=" & $verify)
  excstr.add(" " & moreoptions & " ")
  if verify and sign:
    # build it with TRACE and JSON logs
    exec excstr & " -d:chronicles_log_level=TRACE -d:chronicles_sinks:json" & " tests/" & filename
  # build it again, to run it with less verbose logs
  exec excstr & " -d:chronicles_log_level=INFO -r" & " tests/" & filename
  rmFile "tests/" & filename.toExe

proc buildSample(filename: string, run = false) =
  var excstr = "nim c --opt:speed --threads:on -d:debug --verbosity:0 --hints:off "
  excstr.add(" --warning[CaseTransition]:off --warning[ObservableStores]:off --warning[LockLevel]:off")
  excstr.add(" examples/" & filename)
  exec excstr
  if run:
    exec "./examples/" & filename.toExe
  rmFile "examples/" & filename.toExe

proc buildTutorial(filename: string) =
  discard gorge "cat " & filename & " | nim c -r --hints:off tools/markdown_runner.nim | " &
    " nim --warning[CaseTransition]:off --warning[ObservableStores]:off --warning[LockLevel]:off c -"

task testnative, "Runs libp2p native tests":
  runTest("testnative")

task testdaemon, "Runs daemon tests":
  runTest("testdaemon")

task testinterop, "Runs interop tests":
  runTest("testinterop")

task testpubsub, "Runs pubsub tests":
  runTest("pubsub/testgossipinternal", sign = false, verify = false, moreoptions = "-d:pubsub_internal_testing")
  runTest("pubsub/testpubsub")
  runTest("pubsub/testpubsub", sign = false, verify = false)
  runTest("pubsub/testpubsub", sign = false, verify = false, moreoptions = "-d:libp2p_pubsub_anonymize=true")

task testpubsub_slim, "Runs pubsub tests":
  runTest("pubsub/testgossipinternal", sign = false, verify = false, moreoptions = "-d:pubsub_internal_testing")
  runTest("pubsub/testpubsub")

task testfilter, "Run PKI filter test":
  runTest("testpkifilter",
           moreoptions = "-d:libp2p_pki_schemes=\"secp256k1\"")
  runTest("testpkifilter",
           moreoptions = "-d:libp2p_pki_schemes=\"secp256k1;ed25519\"")
  runTest("testpkifilter",
           moreoptions = "-d:libp2p_pki_schemes=\"secp256k1;ed25519;ecnist\"")
  runTest("testpkifilter",
           moreoptions = "-d:libp2p_pki_schemes=")

task test, "Runs the test suite":
  exec "nimble testnative"
  exec "nimble testpubsub"
  exec "nimble testdaemon"
  exec "nimble testinterop"
  exec "nimble testfilter"
  exec "nimble examples_build"

task test_slim, "Runs the test suite":
  exec "nimble testnative"
  exec "nimble testpubsub_slim"
  exec "nimble testfilter"
  exec "nimble examples_build"

task examples_build, "Build the samples":
  buildSample("directchat")
  buildSample("helloworld", true)
  buildTutorial("examples/tutorial_1_connect.md")
  buildTutorial("examples/tutorial_2_customproto.md")
