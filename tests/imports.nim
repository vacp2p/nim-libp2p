import std/macros
import std/os
import std/strutils
import std/sequtils

proc buildImports(dir: string, ignorePaths: seq[string]): NimNode =
  let imports = newStmtList()
  for file in walkDirRec(dir):
    let (path, name, ext) = splitFile(file)
    let isTestFile = name.startsWith("test_") and not name.startsWith("test_all")
    let isNimFile = ext == ".nim"
    let isIgnored = ignorePaths.len > 0 and ignorePaths.anyIt(path.contains(it))

    if isTestFile and isNimFile and not isIgnored:
      imports.add(newNimNode(nnkImportStmt).add(newLit(file)))
  imports

macro importTests*(dir: static string): untyped =
  ## imports all files in the specified directory whose filename
  ## starts with "test_" and ends in ".nim"
  ## ignores test_all files
  buildImports(dir, @[])

macro importTests*(dir: static string, ignorePaths: static seq[string]): untyped =
  ## imports all files in the specified directory whose filename
  ## starts with "test_" and ends in ".nim"
  ## ignores test_all files and any paths listed in ignorePaths
  buildImports(dir, ignorePaths)
