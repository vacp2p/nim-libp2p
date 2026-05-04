# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import os, osproc, strutils

func isIgnoredRunnableExamplePath(path: string): bool =
  for ignoredPrefix in [".git", "nimbledeps", "nimcache"]:
    if path.contains(ignoredPrefix):
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
  let cmd =
    "nim doc" & " -d:libp2p_autotls_support -d:libp2p_mix_experimental_exit_is_dest" &
    " --index:off --outdir:" & outDir & " " & file
  echo "Checking runnableExamples in " & file
  let code = execCmd cmd
  if code > 0:
    raise newException(CatchableError, "nim doc failed")

for file in walkDirRec ".":
  if file.endsWith(".nim") and not isIgnoredRunnableExamplePath(file) and
      containsRunnableExamples(file):
    try:
      compileFile file
    except CatchableError as e:
      raiseAssert "failed to compile err: " & e.msg & " file:" & file
