mode = ScriptMode.Verbose

packageName = "libp2p"
version = "1.15.3"
author = "Status Research & Development GmbH"
description = "LibP2P implementation"
license = "MIT"
skipDirs = @["cbind", "examples", "interop", "performance", "tests", "tools"]

requires "nim >= 2.0.0",
  "nimcrypto >= 0.6.0", "dnsclient >= 0.3.0 & < 0.4.0", "bearssl >= 0.2.5",
  "chronicles >= 0.11.0", "chronos >= 4.0.4", "metrics", "secp256k1", "stew >= 0.4.2",
  "websock >= 0.2.1", "unittest2", "results", "serialization",
  "https://github.com/vacp2p/nim-lsquic#6ae249c5d9f5eba9999704e1ffe77483cbf8fcdd",
  "https://github.com/vacp2p/nim-jwt.git#18f8378de52b241f321c1f9ea905456e89b95c6f"

import hashes, os, sequtils, strutils

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]

# changes in run configs should be also reflected on flake.nix
let cfg =
  " --styleCheck:usages --styleCheck:error" & (if verbose: "" else: " --verbosity:0") &
  " --skipUserCfg -f" & " --threads:on --opt:speed"

proc runTest(filename: string, moreoptions: string = "") =
  var compileCmd = nimc & " " & lang & " " & cfg & " " & flags
  if getEnv("CICOV").len > 0:
    compileCmd &= " --nimcache:nimcache/" & filename & "-" & $compileCmd.hash
  compileCmd &= " -d:libp2p_autotls_support"
  compileCmd &= " -d:libp2p_mix_experimental_exit_is_dest"
  compileCmd &= " -d:libp2p_gossipsub_1_4"
  compileCmd &= " " & moreoptions & " "

  var runnerArgs = " --output-level=VERBOSE"
  runnerArgs &= " --console"
  runnerArgs &= " --xml:tests/results_" & $hash(filename & $compileCmd) & ".xml"

  # step 1: compile test binary
  exec compileCmd & " tests/" & filename
  # step 2: run binary
  exec "./tests/" & filename.toExe & runnerArgs
  # step 3: remove binary
  rmFile "tests/" & filename.toExe

task testmultiformatexts, "Run multiformat extensions tests":
  let opts =
    "-d:libp2p_multicodec_exts=../tests/libp2p/multiformat_exts/multicodec_exts.nim " &
    "-d:libp2p_multiaddress_exts=../tests/libp2p/multiformat_exts/multiaddress_exts.nim " &
    "-d:libp2p_multihash_exts=../tests/libp2p/multiformat_exts/multihash_exts.nim " &
    "-d:libp2p_multibase_exts=../tests/libp2p/multiformat_exts/multibase_exts.nim " &
    "-d:libp2p_contentids_exts=../tests/libp2p/multiformat_exts/contentids_exts.nim " &
    "-d:path=multiformat_exts"
  runTest("test_all", opts)

task testintegration, "Runs integration tests":
  runTest("integration/test_all")

task test, "Runs the test suite":
  runTest("test_all")
  testmultiformatextsTask()

task testpath, "Run tests matching a specific path":
  var testPathArg = ""

  # Extract arguments after task name
  let params = commandLineParams()
  let taskIdx = params.find("testpath")

  if taskIdx >= 0 and taskIdx < params.len - 1:
    testPathArg = params[taskIdx + 1]

  if testPathArg == "":
    echo "Error: Please provide a test path argument"
    echo "Usage: nimble testpath <path>"
    echo "Example: nimble testpath quic"
    quit(1)

  runTest("test_all", "-d:path=" & testPathArg)

# pin system
# while nimble lockfile
# isn't available

const PinFile = ".pinned"
task pin, "Create a lockfile":
  # pinner.nim was originally here
  # but you can't read output from
  # a command in a nimscript
  exec nimc & " c -r tools/pinner.nim"

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

task format, "Format nim code using nph":
  exec "nph ./. *.nim"
