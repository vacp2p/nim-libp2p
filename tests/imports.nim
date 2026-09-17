# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/algorithm
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
  let normMatch = matchPath.replace('\\', '/')

  var pendingDirs = @[dir]
  while pendingDirs.len > 0:
    for kind, file in walkDir(pendingDirs.pop()):
      if kind == pcDir:
        # Local dependencies and compiler output are not project tests.
        if lastPathPart(file) notin ["nimbledeps", "nimcache"]:
          pendingDirs.add(file)
        continue
      if kind notin {pcFile, pcLinkToFile}:
        continue

      let (path, name, ext) = splitFile(file)
      if not name.startsWith("test_") or name == "test_all" or ext != ".nim":
        continue
      let isIgnored = ignorePaths.len > 0 and ignorePaths.anyIt(path.contains(it))
      # Normalize host paths so forward-slash filters also work on Windows.
      let normFile = file.replace('\\', '/')
      let isMatched = normMatch.len == 0 or normFile.contains(normMatch)

      if not isIgnored and isMatched:
        matchingFiles.add(file)

  # Deterministic order keeps the generated imports stable across runs and platforms.
  sort(
    matchingFiles,
    proc(a, b: string): int =
      cmp(a.replace('\\', '/'), b.replace('\\', '/')),
  )

  for file in matchingFiles:
    imports.add(newNimNode(nnkImportStmt).add(newLit(file)))

  printImportSummary(matchingFiles, dir)

  imports
