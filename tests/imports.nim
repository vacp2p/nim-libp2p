# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/algorithm
import std/json
import std/macros
import std/os
import std/sequtils
import std/strutils

## Partitions the test corpus into named subsystem groups, one CI job each, so a
## failing job names the affected subsystem directly.
## tests/test_groups.json is the single source of truth: the CI matrix derives
## its job list from it (see .github/workflows/ci.yml) and this module reads the
## same file to decide which files each group compiles. The group with an empty
## pattern list is the catch-all for files no named group claims.

const testGroup* {.strdefine.}: string = ""
const groupsJson = staticRead("test_groups.json")

# Test files live under these roots (relative to tests/), each paired with path
# substrings to skip. multiformat_exts is built by its own job with extension
# defines, so it is excluded from the regular groups.
const testRoots = [
  ("libp2p", @["multiformat_exts"]),
  ("interop", newSeq[string]()),
  ("tools", newSeq[string]()),
]

type Group = tuple[name: string, patterns: seq[string]]

proc loadGroups(): seq[Group] {.compileTime.} =
  var groups: seq[Group]
  for name, patterns in groupsJson.parseJson():
    groups.add((name, patterns.getElems().mapIt(it.getStr())))
  groups

proc catchAll(groups: seq[Group]): string {.compileTime.} =
  let empties = groups.filterIt(it.patterns.len == 0).mapIt(it.name)
  doAssert empties.len == 1,
    "test_groups.json needs exactly one catch-all (empty patterns); got " & $empties
  empties[0]

proc groupOf(file: string, groups: seq[Group]): string {.compileTime.} =
  let norm = file.replace('\\', '/')
  var hits: seq[string]
  for g in groups:
    for pattern in g.patterns:
      if norm.contains(pattern):
        hits.add(g.name)
        break
  doAssert hits.len <= 1,
    "test file " & norm & " is claimed by multiple groups: " & $hits
  if hits.len == 1:
    return hits[0]
  catchAll(groups)

proc isTestModule(name, ext: string): bool {.compileTime.} =
  ext == ".nim" and name.startsWith("test_") and name != "test_all"

proc gatherTests(dir: string, ignore: seq[string]): seq[string] {.compileTime.} =
  var files: seq[string]
  for file in walkDirRec(dir):
    let (path, name, ext) = file.splitFile()
    if isTestModule(name, ext) and not ignore.anyIt(path.contains(it)):
      files.add(file)
  files

proc sortedByPath(files: seq[string]): seq[string] {.compileTime.} =
  var sorted = files
  sorted.sort(
    proc(a, b: string): int =
      cmp(a.replace('\\', '/'), b.replace('\\', '/'))
  )
  sorted

proc collectTestFiles(testsDir: string): seq[string] {.compileTime.} =
  var files: seq[string]
  for (root, ignore) in testRoots:
    files.add(gatherTests(testsDir / root, ignore))
  sortedByPath(files)

proc printImportSummary(importedFiles: seq[string], label: string) =
  echo "\n=================================="
  echo "Test group '", label, "': imported ", importedFiles.len, " files."
  for file in importedFiles:
    echo "  ", file.replace('\\', '/')
  echo "==================================\n"

macro importTestGroup*(testsDir: static string, group: static string): untyped =
  ## Imports the test files belonging to `group` (empty imports every group, for
  ## a local `make test`). Reads tests/test_groups.json for the partition and
  ## asserts at compile time that it stays total and disjoint.
  let groups = loadGroups()
  let names = groups.mapIt(it.name)
  doAssert group.len == 0 or group in names,
    "unknown test group '" & group & "'; defined in test_groups.json: " & $names

  let files = collectTestFiles(testsDir)

  # A named group that matches nothing means its directory was renamed/removed
  # and its tests would silently stop running — fail loudly instead.
  for g in groups:
    if g.patterns.len == 0:
      continue
    doAssert files.anyIt(groupOf(it, groups) == g.name),
      "test group '" & g.name & "' matches no files — was a directory renamed?"

  let imports = newStmtList()
  var imported: seq[string]
  for file in files:
    if group.len == 0 or groupOf(file, groups) == group:
      imports.add(newNimNode(nnkImportStmt).add(newLit(file)))
      imported.add(file)

  var label = group
  if label.len == 0:
    label = "all"
  printImportSummary(imported, label)
  imports

macro importTests*(
    dir: static string, ignorePaths: static seq[string], matchPath: static string = ""
): untyped =
  ## Recursively imports test_*.nim under `dir`, skipping `ignorePaths` and, when
  ## `matchPath` is set, keeping only files whose path contains that substring.
  ## Used by `make test <path>` for ad-hoc runs.
  let normMatch = matchPath.replace('\\', '/')
  var matching = gatherTests(dir, ignorePaths)
  if normMatch.len > 0:
    matching = matching.filterIt(it.replace('\\', '/').contains(normMatch))
  matching = sortedByPath(matching)

  let imports = newStmtList()
  var imported: seq[string]
  for file in matching:
    imports.add(newNimNode(nnkImportStmt).add(newLit(file)))
    imported.add(file)
  printImportSummary(imported, "path:" & matchPath)
  imports
