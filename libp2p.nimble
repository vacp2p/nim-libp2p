mode = ScriptMode.Verbose

packageName   = "libp2p"
version       = "1.1.0"
author        = "Status Research & Development GmbH"
description   = "LibP2P implementation"
license       = "MIT"
skipDirs      = @["tests", "examples", "Nim", "tools", "scripts", "docs"]

requires "nim >= 1.6.0",
         "nimcrypto >= 0.4.1",
         "dnsclient >= 0.3.0 & < 0.4.0",
         "bearssl >= 0.1.4",
         "chronicles >= 0.10.2",
         "chronos >= 3.0.6",
         "metrics",
         "secp256k1",
         "stew#head",
         "websock",
         "unittest2 >= 0.0.5 & < 0.1.0"


proc requireDeps(name: string) = taskRequires name, "nimpng#HEAD", "nico"

requireDeps "test"
requireDeps "test_slim"
requireDeps "examples_build"

import hashes

proc runTest(filename: string, verify: bool = true, sign: bool = true,
             moreoptions: string = "") =
  var excstr = "nim c --skipParentCfg --opt:speed -d:debug "
  excstr.add(" " & getEnv("NIMFLAGS") & " ")
  excstr.add(getPathsClause())
  excstr.add(" --verbosity:0 --hints:off ")
  excstr.add(" -d:libp2p_pubsub_sign=" & $sign)
  excstr.add(" -d:libp2p_pubsub_verify=" & $verify)
  excstr.add(" " & moreoptions & " ")
  if getEnv("CICOV").len > 0:
    excstr &= " --nimcache:nimcache/" & filename & "-" & $excstr.hash
  exec excstr & " -r " & " tests/" & filename
  rmFile "tests/" & filename.toExe

proc buildSample(filename: string, run = false, extraFlags = "") =
  var excstr = "nim c --opt:speed --threads:on -d:debug --verbosity:0 --hints:off -p:. " & extraFlags
  excstr.add " " & getPathsClause()
  excstr.add(" examples/" & filename)
  exec excstr
  if run:
    exec "./examples/" & filename.toExe
  rmFile "examples/" & filename.toExe

proc tutorialToMd(filename: string) =
  let markdown = gorge "cat " & filename & " | nim c -r --verbosity:0 --hints:off tools/markdown_builder.nim "
  writeFile(filename.replace(".nim", ".md"), markdown)

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
  exec nimbleExe & " -y testnative"
  exec nimbleExe & " -y testpubsub"
  exec nimbleExe & " -y testdaemon"
  exec nimbleExe & " -y testinterop"
  exec nimbleExe & " -y testfilter"
  exec nimbleExe & " -y examples_build"

task test_slim, "Runs the (slimmed down) test suite":
  exec nimbleExe & " -y testnative"
  exec nimbleExe & " -y testpubsub_slim"
  exec nimbleExe & " -y testfilter"
  exec nimbleExe & " -y examples_build"

task website, "Build the website":
  tutorialToMd("examples/tutorial_1_connect.nim")
  tutorialToMd("examples/tutorial_2_customproto.nim")
  tutorialToMd("examples/tutorial_3_protobuf.nim")
  tutorialToMd("examples/tutorial_4_gossipsub.nim")
  tutorialToMd("examples/tutorial_5_discovery.nim")
  tutorialToMd("examples/tutorial_6_game.nim")
  tutorialToMd("examples/circuitrelay.nim")
  exec "mkdocs build"

task examples_build, "Build the samples":
  buildSample("directchat")
  buildSample("helloworld", true)
  buildSample("circuitrelay", true)
  buildSample("tutorial_1_connect", true)
  buildSample("tutorial_2_customproto", true)
  buildSample("tutorial_3_protobuf", true)
  buildSample("tutorial_4_gossipsub", true)
  buildSample("tutorial_5_discovery", true)
  buildSample("tutorial_6_game", false, "--styleCheck:off")
