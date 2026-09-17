# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import os, osproc, strutils

func isIgnoredRunnableExamplePath(path: string): bool =
  let normalizedPath = path.replace('\\', '/')
  for component in normalizedPath.split('/'):
    if component in [".git", "nim", "nimbledeps", "nimcache"]:
      return true
  false

proc containsRunnableExamples(path: string): bool =
  for line in lines(path):
    if "runnableExamples" in line:
      return true
  false

let outDir = "nimcache/runnable_examples"
createDir outDir

proc exampleSearchPaths(): string =
  # `nim doc` forwards search paths (`--path`) to the runnableExamples
  # subcompilation, but not the project root nor lazy `NimblePath` entries.
  # Pass the repo root (so examples can `import libp2p/...`) and each local
  # dependency (e.g. chronos) explicitly.
  var flags = @["--path:" & quoteShell(getCurrentDir())]
  let pkgsDir = "nimbledeps" / "pkgs2"
  if dirExists(pkgsDir):
    for kind, path in walkDir(pkgsDir):
      if kind in {pcDir, pcLinkToDir}:
        flags.add("--path:" & quoteShell(path))
  flags.join(" ")

proc compileFile(file: string) =
  let cmd =
    "nim doc --index:off " & exampleSearchPaths() & " --outdir:" & outDir & " " & file

  echo "Checking runnableExamples in " & file
  let code = execCmd cmd
  if code != 0:
    raise newException(
      CatchableError, "nim doc failed for file: " & file & " exit code: " & $code
    )

iterator walkNimFiles(rootDir: string): string =
  var dirs = @[rootDir]
  while dirs.len > 0:
    let currentDir = dirs.pop()
    for entry in walkDir(currentDir):
      if isIgnoredRunnableExamplePath(entry.path):
        continue

      case entry.kind
      of pcDir:
        dirs.add(entry.path)
      of pcFile:
        if entry.path.endsWith(".nim"):
          yield entry.path
      else:
        discard

for file in walkNimFiles("."):
  if containsRunnableExamples(file):
    compileFile file
