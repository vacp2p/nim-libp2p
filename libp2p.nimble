mode = ScriptMode.Verbose

packageName   = "libp2p"
version       = "0.0.2"
author        = "Status Research & Development GmbH"
description   = "LibP2P implementation"
license       = "MIT"
skipDirs      = @["tests", "examples", "Nim", "tools", "scripts", "docs"]

requires "nim >= 1.2.0",
         "nimcrypto >= 0.4.1",
         "dnsclient >= 0.1.2",
         "bearssl >= 0.1.4",
         "chronicles >= 0.10.2",
         "chronos >= 3.0.6",
         "https://github.com/status-im/nim-quic.git",
         "metrics",
         "secp256k1",
         "stew#head",
         "websock"

const styleCheckStyle =
  if (NimMajor, NimMinor) < (1, 6):
    "hint"
  else:
    "error"

const nimflags =
  "--verbosity:0 --hints:off " &
  "--warning[CaseTransition]:off --warning[ObservableStores]:off " &
  "--warning[LockLevel]:off " &
  "-d:chronosStrictException " &
  "--styleCheck:usages --styleCheck:" & styleCheckStyle & " "

proc runTest(filename: string, verify: bool = true, sign: bool = true,
             moreoptions: string = "") =
  var excstr = "nim c --opt:speed -d:debug -d:libp2p_agents_metrics -d:libp2p_protobuf_metrics -d:libp2p_network_protocols_metrics -d:libp2p_mplex_metrics "
  excstr.add(" -d:chronicles_sinks=textlines[stdout],json[dynamic] -d:chronicles_log_level=TRACE ")
  excstr.add(" -d:chronicles_runtime_filtering=TRUE ")
  excstr.add(" " & getEnv("NIMFLAGS") & " ")
  excstr.add(" " & nimflags & " ")
  excstr.add(" -d:libp2p_pubsub_sign=" & $sign)
  excstr.add(" -d:libp2p_pubsub_verify=" & $verify)
  excstr.add(" " & moreoptions & " ")
  exec excstr & " -r " & " tests/" & filename
  rmFile "tests/" & filename.toExe

proc buildSample(filename: string, run = false) =
  var excstr = "nim c --opt:speed --threads:on -d:debug "
  excstr.add(" " & nimflags & " ")
  excstr.add(" examples/" & filename)
  exec excstr
  if run:
    exec "./examples/" & filename.toExe
  rmFile "examples/" & filename.toExe

proc buildTutorial(filename: string) =
  discard gorge "cat " & filename & " | nim c -r --hints:off tools/markdown_runner.nim | " &
    " nim " & nimflags & " c -"

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

task test_slim, "Runs the (slimmed down) test suite":
  exec "nimble testnative"
  exec "nimble testpubsub_slim"
  exec "nimble testfilter"
  exec "nimble examples_build"

task examples_build, "Build the samples":
  buildSample("directchat")
  buildSample("helloworld", true)
  buildTutorial("examples/tutorial_1_connect.md")
  buildTutorial("examples/tutorial_2_customproto.md")

proc tutorialToHtml(source, output: string) =
  var html = gorge("./nimbledeps/bin/markdown < " & source)
  html &= """
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/water.css@2/out/water.css">
<link rel="stylesheet" href="https://unpkg.com/@highlightjs/cdn-assets@11.5.1/styles/default.min.css">
<script src="https://unpkg.com/@highlightjs/cdn-assets@11.5.1/highlight.min.js"></script>
<script src="https://unpkg.com/@highlightjs/cdn-assets@11.5.1/languages/nim.min.js"></script>
<script>hljs.highlightAll();</script>
  """
  writeFile(output, html)


task markdown_to_html, "Build the tutorials HTML":
  exec "nimble install -y markdown"
  tutorialToHtml("examples/tutorial_1_connect.md", "tuto1.html")
  tutorialToHtml("examples/tutorial_2_customproto.md", "tuto2.html")

# pin system
# while nimble lockfile
# isn't available

const PinFile = ".pinned"
task pin, "Create a lockfile":
  # pinner.nim was originally here
  # but you can't read output from
  # a command in a nimscript
  exec "nim c -r tools/pinner.nim"

import sequtils
import os
task install_pinned, "Reads the lockfile":
  let toInstall = readFile(PinFile).splitWhitespace().mapIt((it.split(";", 1)[0], it.split(";", 1)[1]))
  # [('packageName', 'packageFullUri')]

  rmDir("nimbledeps")
  mkDir("nimbledeps")
  exec "nimble install -y " & toInstall.mapIt(it[1]).join(" ")

  # Remove the automatically installed deps
  # (inefficient you say?)
  let allowedDirectories = toInstall.mapIt(it[0] & "-" & it[1].split('@')[1])
  for dependency in listDirs("nimbledeps/pkgs"):
    if dependency.extractFilename notin allowedDirectories:
      rmDir(dependency)

task unpin, "Restore global package use":
  rmDir("nimbledeps")
