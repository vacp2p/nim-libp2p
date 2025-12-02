# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/macros
import std/os
import std/strutils
import std/sequtils

proc printImportSummary(importedFiles: seq[string], baseDir: string) =
  ## Prints a summary of imported test files at compile time
  echo "\n"
  echo "=================================="
  echo "Dynamic test import"
  echo "Imported ", importedFiles.len, " files."
  echo ""
  for file in importedFiles:
    # Compute relative path from the base directory
    let relPath = file.replace(baseDir & DirSep, "")
    echo relPath
  echo "=================================="
  echo "\n"

macro importTests*(
    dir: static string, ignorePaths: static seq[string], matchPath: static string
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
  var importedFiles: seq[string] = @[]

  for file in walkDirRec(dir):
    let (path, name, ext) = splitFile(file)
    let isTestFile = name.startsWith("test_") and name != "test_all" and ext == ".nim"
    let isIgnored = ignorePaths.len > 0 and ignorePaths.anyIt(path.contains(it))
    let isMatched = matchPath.len == 0 or file.contains(matchPath)

    if isTestFile and not isIgnored and isMatched:
      imports.add(newNimNode(nnkImportStmt).add(newLit(file)))
      importedFiles.add(file)

  printImportSummary(importedFiles, dir)

  imports
