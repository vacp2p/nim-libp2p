# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/algorithm
import std/macros
import std/os
import std/strutils
import std/sequtils

# Split the test corpus across `sliceTotal` translation units; each invocation
# of test_all.nim compiles only the files whose sorted index is `sliceIdx` mod
# `sliceTotal`. On 32-bit targets the Nim compiler is itself a 32-bit process
# and is capped at ~3 GB of address space, which the unsharded TU overran on
# orc. Slicing keeps each compile under that ceiling and is a no-op when
# sliceTotal == 1.
const sliceTotal* {.intdefine.}: int = 1
const sliceIdx* {.intdefine.}: int = 0
static:
  doAssert sliceTotal >= 1, "sliceTotal must be >= 1"
  doAssert sliceIdx >= 0 and sliceIdx < sliceTotal,
    "sliceIdx must be in [0, sliceTotal)"

proc printImportSummary(importedFiles: seq[string], baseDir: string) =
  ## Prints a summary of imported test files at compile time
  echo "\n"
  echo "=================================="
  echo "Dynamic test import (slice ", sliceIdx, "/", sliceTotal, ")"
  echo "Imported ", importedFiles.len, " files."
  echo ""
  for file in importedFiles:
    # Compute relative path
    let parentDir = baseDir.parentDir()
    let relPath = file.replace(parentDir & DirSep, "")
    echo relPath
  echo "=================================="
  echo "\n"

macro importTests*(
    dir: static string, ignorePaths: static seq[string], matchPath: static string = ""
): untyped =
  ## Recursively imports test files matching "test_*.nim" (excluding "test_all.nim").
  ##
  ## - `dir`: Root directory to scan
  ## - `ignorePaths`: Path substrings to exclude (e.g., @["transports"])
  ## - `matchPath`: Path substring to match (e.g., "quic")
  ##
  ## **Behavior changes based on `matchPath`:**
  ## - When `matchPath == ""`: imports ALL matching tests (filtered only by `ignorePaths`)
  ## - When `matchPath != ""`: imports ONLY tests whose path contains `matchPath` substring
  ##
  ## Example: `importTests("tests", @[], "quic")` imports only QUIC-related tests
  let imports = newStmtList()
  var matchingFiles: seq[string] = @[]

  for file in walkDirRec(dir):
    let (path, name, ext) = splitFile(file)
    let isTestFile = name.startsWith("test_") and name != "test_all" and ext == ".nim"
    let isIgnored = ignorePaths.len > 0 and ignorePaths.anyIt(path.contains(it))
    # walkDirRec uses the host's path separator; normalize so callers can pass
    # forward-slash matchPath values that work on Windows too.
    let normFile = file.replace('\\', '/')
    let normMatch = matchPath.replace('\\', '/')
    let isMatched = normMatch.len == 0 or normFile.contains(normMatch)

    if isTestFile and not isIgnored and isMatched:
      matchingFiles.add(file)

  # Deterministic order so a given (sliceIdx, sliceTotal) always selects the
  # same set across runs and platforms.
  sort(
    matchingFiles,
    proc(a, b: string): int =
      cmp(a.replace('\\', '/'), b.replace('\\', '/')),
  )

  var importedFiles: seq[string] = @[]
  for i, file in matchingFiles:
    if i mod sliceTotal == sliceIdx:
      imports.add(newNimNode(nnkImportStmt).add(newLit(file)))
      importedFiles.add(file)

  printImportSummary(importedFiles, dir)

  imports
