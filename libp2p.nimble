mode = ScriptMode.Verbose

packageName = "libp2p"
version = "1.14.3"
author = "Status Research & Development GmbH"
description = "LibP2P implementation"
license = "MIT"
skipDirs = @["cbind", "examples", "interop", "performance", "tests", "tools"]

requires "nim >= 2.0.0",
  "nimcrypto >= 0.6.0", "dnsclient >= 0.3.0 & < 0.4.0", "bearssl >= 0.2.5",
  "chronicles >= 0.11.0", "chronos >= 4.0.4", "metrics", "secp256k1", "stew >= 0.4.2",
  "websock >= 0.2.1", "unittest2", "results", "taskpools >= 0.1.0",
  "https://github.com/vacp2p/nim-lsquic#17facd66ac87291323b3d84a9c4dec91f3c73744",
  "https://github.com/vacp2p/nim-jwt.git#18f8378de52b241f321c1f9ea905456e89b95c6f"

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") & " --skipUserCfg -f" &
  " --threads:on --opt:speed"

import hashes, strutils, os

proc runTest(filename: string, moreoptions: string = "") =
  var compileCmd = nimc & " " & lang & " -d:debug " & cfg & " " & flags
  if getEnv("CICOV").len > 0:
    compileCmd &= " --nimcache:nimcache/" & filename & "-" & $compileCmd.hash
  compileCmd &= " -d:libp2p_autotls_support"
  compileCmd &= " -d:libp2p_mix_experimental_exit_is_dest"
  compileCmd &= " -d:libp2p_gossipsub_1_4"
  compileCmd &= " " & moreoptions & " "

  var runnerArgs = " --output-level=VERBOSE"
  runnerArgs &= " --console"
  runnerArgs &= " --xml:tests/results_" & filename.replace("/", "_") & ".xml"

  # step 1: compile test binary
  exec compileCmd & " tests/" & filename
  # step 2: run binary
  exec "./tests/" & filename.toExe & runnerArgs
  # step 3: remove binary
  rmFile "tests/" & filename.toExe

proc buildSample(filename: string, run = false, extraFlags = "") =
  var excstr = nimc & " " & lang & " " & cfg & " " & flags & " -p:. " & extraFlags
  excstr.add(" examples/" & filename)
  exec excstr
  if run:
    exec "./examples/" & filename.toExe
  rmFile "examples/" & filename.toExe

proc buildCBindings(libType: string, params = "") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2 ..< paramCount():
    extra_params &= " " & paramStr(i)

  let ext =
    if libType == "static":
      "a"
    else:
      when defined(windows):
        "dll"
      elif defined(macosx):
        "dylib"
      else:
        "so"
  let app = if libType == "static": "staticlib" else: "lib"

  exec nimc & " " & lang & " --out:build/libp2p." & ext & " --threads:on --app:" & app &
    " --opt:size --noMain --mm:refc --header --undef:metrics --nimMainPrefix:libp2p --nimcache:nimcache -d:asyncTimer=system " &
    cfg & " " & flags & " cbind/libp2p.nim"

proc tutorialToMd(filename: string) =
  let markdown = gorge "cat " & filename & " | " & nimc & " " & lang &
    " -r --verbosity:0 --hints:off tools/markdown_builder.nim "
  writeFile(filename.replace(".nim", ".md"), markdown)

task testmultiformatexts, "Run multiformat extensions tests":
  let opts =
    "-d:libp2p_multicodec_exts=../tests/libp2p/multiformat_exts/multicodec_exts.nim " &
    "-d:libp2p_multiaddress_exts=../tests/libp2p/multiformat_exts/multiaddress_exts.nim " &
    "-d:libp2p_multihash_exts=../tests/libp2p/multiformat_exts/multihash_exts.nim " &
    "-d:libp2p_multibase_exts=../tests/libp2p/multiformat_exts/multibase_exts.nim " &
    "-d:libp2p_contentids_exts=../tests/libp2p/multiformat_exts/contentids_exts.nim "
  runTest("libp2p/multiformat_exts/test_all", opts)

task testpubsub, "Runs pubsub tests":
  runTest("libp2p/pubsub/test_all", "-d:libp2p_gossipsub_1_4")

task testintegration, "Runs integration tests":
  runTest("integration/test_all")

task test, "Runs the test suite":
  runTest("test_all")
  testmultiformatextsTask()

task website, "Build the website":
  tutorialToMd("examples/tutorial_1_connect.nim")
  tutorialToMd("examples/tutorial_2_customproto.nim")
  tutorialToMd("examples/tutorial_3_protobuf.nim")
  tutorialToMd("examples/tutorial_4_gossipsub.nim")
  tutorialToMd("examples/circuitrelay.nim")
  exec "mkdocs build"

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

task libDynamic, "Generate dynamic bindings":
  buildCBindings "dynamic", ""

task libStatic, "Generate static bindings":
  buildCBindings "static", ""

task examples, "Build and run examples":
  exec "nimble install -y nimpng"
  exec "nimble install -y nico --passNim=--skipParentCfg"
  buildSample("examples_build", false, "--styleCheck:off") # build only

  buildSample("examples_run", true)

  buildCBindings "static", ""
  exec "g++ -o build/cbindings ./examples/cbindings.c ./build/libp2p.a -pthread"
  exec "./build/cbindings"
