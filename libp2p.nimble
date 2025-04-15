mode = ScriptMode.Verbose

packageName = "libp2p"
version = "1.9.0"
author = "Status Research & Development GmbH"
description = "LibP2P implementation"
license = "MIT"
skipDirs = @["tests", "examples", "Nim", "tools", "scripts", "docs"]

requires "nim >= 1.6.0",
  "nimcrypto >= 0.6.0 & < 0.7.0", "dnsclient >= 0.3.0 & < 0.4.0", "bearssl >= 0.2.5",
  "chronicles >= 0.10.2", "chronos >= 4.0.3", "metrics", "secp256k1", "stew#head",
  "websock", "unittest2",
  "https://github.com/status-im/nim-quic.git#d54e8f0f2e454604b767fadeae243d95c30c383f"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") & " --skipUserCfg -f" &
  " --threads:on --opt:speed"

import hashes, strutils

proc runTest(
    filename: string, verify: bool = true, sign: bool = true, moreoptions: string = ""
) =
  var excstr = nimc & " " & lang & " -d:debug " & cfg & " " & flags
  excstr.add(" -d:libp2p_pubsub_sign=" & $sign)
  excstr.add(" -d:libp2p_pubsub_verify=" & $verify)
  excstr.add(" " & moreoptions & " ")
  if getEnv("CICOV").len > 0:
    excstr &= " --nimcache:nimcache/" & filename & "-" & $excstr.hash
  exec excstr & " -r " & " tests/" & filename
  rmFile "tests/" & filename.toExe

proc buildSample(filename: string, run = false, extraFlags = "") =
  var excstr = nimc & " " & lang & " " & cfg & " " & flags & " -p:. " & extraFlags
  excstr.add(" examples/" & filename)
  exec excstr
  if run:
    exec "./examples/" & filename.toExe
  rmFile "examples/" & filename.toExe

proc tutorialToMd(filename: string) =
  let markdown = gorge "cat " & filename & " | " & nimc & " " & lang &
    " -r --verbosity:0 --hints:off tools/markdown_builder.nim "
  writeFile(filename.replace(".nim", ".md"), markdown)

task testnative, "Runs libp2p native tests":
  runTest("testnative")

task testnative2, "Runs libp2p native tests":
  runTest("testnative2")

task testnative3, "Runs libp2p native tests":
  runTest("testnative3")

task testnative4, "Runs libp2p native tests":
  runTest("testnative4")
  
task testnative5, "Runs libp2p native tests":
  runTest("testnative5")

task testdaemon, "Runs daemon tests":
  runTest("testdaemon")

task testinterop, "Runs interop tests":
  runTest("testinterop")

task testpubsub, "Runs pubsub tests":
  runTest(
    "pubsub/testgossipinternal",
    sign = false,
    verify = false,
    moreoptions = "-d:pubsub_internal_testing",
  )
  runTest("pubsub/testpubsub")
  runTest("pubsub/testpubsub", sign = false, verify = false)
  runTest(
    "pubsub/testpubsub",
    sign = false,
    verify = false,
    moreoptions = "-d:libp2p_pubsub_anonymize=true",
  )

task testpubsub_slim, "Runs pubsub tests":
  runTest(
    "pubsub/testgossipinternal",
    sign = false,
    verify = false,
    moreoptions = "-d:pubsub_internal_testing",
  )
  runTest("pubsub/testpubsub")

task testfilter, "Run PKI filter test":
  runTest("testpkifilter", moreoptions = "-d:libp2p_pki_schemes=\"secp256k1\"")
  runTest("testpkifilter", moreoptions = "-d:libp2p_pki_schemes=\"secp256k1;ed25519\"")
  runTest(
    "testpkifilter", moreoptions = "-d:libp2p_pki_schemes=\"secp256k1;ed25519;ecnist\""
  )
  runTest("testpkifilter", moreoptions = "-d:libp2p_pki_schemes=")

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
  exec "nimble install -y nimpng"
  exec "nimble install -y nico --passNim=--skipParentCfg"
  buildSample("tutorial_6_game", false, "--styleCheck:off")

# pin system
# while nimble lockfile
# isn't available

const PinFile = ".pinned"
task pin, "Create a lockfile":
  # pinner.nim was originally here
  # but you can't read output from
  # a command in a nimscript
  exec nimc & " c -r tools/pinner.nim"

import sequtils
import os
task install_pinned, "Reads the lockfile":
  let toInstall = readFile(PinFile).splitWhitespace().mapIt(
      (it.split(";", 1)[0], it.split(";", 1)[1])
    )
  # [('packageName', 'packageFullUri')]

  rmDir("nimbledeps")
  mkDir("nimbledeps")
  exec "nimble install -y " & toInstall.mapIt(it[1]).join(" ")

  # Remove the automatically installed deps
  # (inefficient you say?)
  let nimblePkgs =
    if system.dirExists("nimbledeps/pkgs"): "nimbledeps/pkgs" else: "nimbledeps/pkgs2"
  for dependency in listDirs(nimblePkgs):
    let
      fileName = dependency.extractFilename
      fileContent = readFile(dependency & "/nimblemeta.json")
      packageName = fileName.split('-')[0]

    if toInstall.anyIt(
      it[0] == packageName and (
        it[1].split('#')[^1] in fileContent or # nimble for nim 2.X
        fileName.endsWith(it[1].split('#')[^1]) # nimble for nim 1.X
      )
    ) == false or fileName.split('-')[^1].len < 20: # safegard for nimble for nim 1.X
      rmDir(dependency)

task unpin, "Restore global package use":
  rmDir("nimbledeps")
