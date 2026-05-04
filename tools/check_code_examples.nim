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

for file in walkDirRec ".":
  if file.endsWith(".nim") and not isIgnoredRunnableExamplePath(file) and
      containsRunnableExamples(file):
    compileFile file
