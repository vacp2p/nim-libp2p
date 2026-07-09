mode = ScriptMode.Verbose

packageName = "tests"
version = "1.0.0"
author = "Status Research & Development GmbH"
description = "Tests for LibP2P implementation"
license = "MIT"

import os, sequtils, strutils

requires "libbacktrace", "unittest2"

task install_pinned, "Install tests' pinned deps":
  let toInstall = readFile(".pinned").splitWhitespace().mapIt(
      (it.split(";", 1)[0], it.split(";", 1)[1])
    )

  if dirExists("nimbledeps"):
    rmDir("nimbledeps")
  mkDir("nimbledeps")
  exec "nimble install -y " & toInstall.mapIt(it[1]).join(" ")

  let nimblePkgs =
    if system.dirExists("nimbledeps/pkgs"): "nimbledeps/pkgs" else: "nimbledeps/pkgs2"
  for dependency in listDirs(nimblePkgs):
    let
      fileName = dependency.extractFilename
      fileContent = readFile(dependency & "/nimblemeta.json")
      packageName = fileName.split('-')[0]

    if not toInstall.anyIt(it[0] == packageName and it[1].split('#')[^1] in fileContent):
      rmDir(dependency)
