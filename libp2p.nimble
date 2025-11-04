mode = ScriptMode.Verbose

packageName = "libp2p"
version = "1.14.3"
author = "Status Research & Development GmbH"
description = "LibP2P implementation"
license = "MIT"
skipDirs = @["tests", "examples", "Nim", "tools", "scripts", "docs"]

# Nim version check - prevents doing any nimble task if 
# version is not satisfied to show more cleaner error to user.
when (NimMajor, NimMinor) < (2, 0):
  {.error: "nim-libp2p requires Nim v2.0 or v2.2".}

requires "nim >= 2.0.0"

requires "nimcrypto >= 0.6.0",
  "dnsclient >= 0.3.0 & < 0.4.0", "bearssl >= 0.2.5", "chronicles >= 0.11.0",
  "chronos >= 4.0.4", "metrics", "secp256k1", "stew >= 0.4.2", "websock >= 0.2.1",
  "unittest2", "results", "quic >= 0.5.0",
  "https://github.com/vacp2p/nim-jwt.git#18f8378de52b241f321c1f9ea905456e89b95c6f"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") & " --skipUserCfg -f" &
  " --threads:on --opt:speed"

import hashes, strutils

proc runTest(filename: string, moreoptions: string = "") =
  var compileCmd = nimc & " " & lang & " -d:debug " & cfg & " " & flags
  if getEnv("CICOV").len > 0:
    compileCmd &= " --nimcache:nimcache/" & filename & "-" & $compileCmd.hash
  compileCmd &= " -d:libp2p_autotls_support"
  compileCmd &= " -d:libp2p_mix_experimental_exit_is_dest"
  compileCmd &= " -d:libp2p_gossipsub_1_4"
  compileCmd &= " " & moreoptions & " "

  # step 1: compile test binary
  exec compileCmd & " tests/" & filename
  # step 2: run binary
  exec "./tests/" & filename.toExe & " --output-level=VERBOSE"
  # step 3: remove binary
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

task testmultiformatexts, "Run multiformat extensions tests":
  let opts =
    "-d:libp2p_multicodec_exts=../tests/multiformat_exts/multicodec_exts.nim " &
    "-d:libp2p_multiaddress_exts=../tests/multiformat_exts/multiaddress_exts.nim " &
    "-d:libp2p_multihash_exts=../tests/multiformat_exts/multihash_exts.nim " &
    "-d:libp2p_multibase_exts=../tests/multiformat_exts/multibase_exts.nim " &
    "-d:libp2p_contentids_exts=../tests/multiformat_exts/contentids_exts.nim "
  runTest("multiformat_exts/testmultiformat_exts", opts)

task testnative, "Runs libp2p native tests":
  runTest("testnative")

task testpubsub, "Runs pubsub tests":
  runTest("pubsub/testpubsub", "-d:libp2p_gossipsub_1_4")

task testfilter, "Run PKI filter test":
  runTest("testpkifilter")

task testintegration, "Runs integraion tests":
  runTest("testintegration")

task test, "Runs the test suite":
  runTest("testall")
  testmultiformatextsTask()

task website, "Build the website":
  tutorialToMd("examples/tutorial_1_connect.nim")
  tutorialToMd("examples/tutorial_2_customproto.nim")
  tutorialToMd("examples/tutorial_3_protobuf.nim")
  tutorialToMd("examples/tutorial_4_gossipsub.nim")
  tutorialToMd("examples/tutorial_5_discovery.nim")
  tutorialToMd("examples/tutorial_6_game.nim")
  tutorialToMd("examples/circuitrelay.nim")
  exec "mkdocs build"

task examples, "Build and run examples":
  exec "nimble install -y nimpng"
  exec "nimble install -y nico --passNim=--skipParentCfg"
  buildSample("examples_build", false, "--styleCheck:off") # build only

  buildSample("examples_run", true)

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
