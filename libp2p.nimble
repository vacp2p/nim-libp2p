mode = ScriptMode.Verbose

packageName = "libp2p"
version = "2.0.0"
author = "Status Research & Development GmbH"
description = "LibP2P implementation"
license = "MIT"
skipDirs =
  @["cbind", "examples", "interop", "performance", "simulation", "tests", "tools"]

requires "nim >= 2.2.4",
  "nimcrypto >= 0.6.0", "bearssl >= 0.2.7",
  "https://github.com/vacp2p/nim-boringssl >= 0.0.8", "chronicles >= 0.11.0",
  "chronos >= 4.2.2", "metrics >= 0.2.2", "secp256k1", "stew >= 0.4.2", "unittest2",
  "results", "serialization", "lsquic >= 0.5.1", "protobuf_serialization >= 0.4.0",
  "https://github.com/status-im/nim-websock >= 0.4.0",
  "https://github.com/status-im/nim-nat-traversal >= 0.0.1"

import os, sequtils, strutils

let nimc = getEnv("NIMC", "nim")

# pin system
# while nimble lockfile
# isn't available

const PinFile = ".pinned"
task pin, "Create a lockfile":
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

    if not toInstall.anyIt(it[0] == packageName and it[1].split('#')[^1] in fileContent):
      rmDir(dependency)

task unpin, "Restore global package use":
  rmDir("nimbledeps")

task gen_multicodec,
  "Download the multicodec CSV and regenerate libp2p/multicodec_table.nim":
  exec nimc & " c -r tools/gen_multicodec.nim"
