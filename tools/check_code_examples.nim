# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import os, osproc, strutils

func isIgnoredRunnableExamplePath(path: string): bool =
  let normalizedPath = path.replace('\\', '/')
  for component in normalizedPath.split('/'):
    if component in [".git", "nimbledeps", "nimcache"]:
      return true
  false

proc containsRunnableExamples(path: string): bool =
  for line in lines(path):
    if "runnableExamples" in line:
      return true
  false

let outDir = "nimcache/runnable_examples"
createDir outDir

proc compileFile(file: string) =
  let cmd = "nim doc --index:off --outdir:" & outDir & " " & file

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
