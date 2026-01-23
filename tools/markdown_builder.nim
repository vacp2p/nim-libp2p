# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import os, strutils

let contents =
  if paramCount() > 0:
    readFile(paramStr(1))
  else:
    stdin.readAll()

var code = ""
for line in contents.splitLines(true):
  let
    stripped = line.strip()
    isMarkdown = stripped.startsWith("##")

  if isMarkdown:
    if code.strip.len > 0:
      echo "```nim"
      echo code.strip(leading = false)
      echo "```"
      code = ""
    echo(
      if stripped.len > 3:
        stripped[3 ..^ 1]
      else:
        ""
    )
  else:
    code &= line
if code.strip.len > 0:
  echo ""
  echo "```nim"
  echo code
  echo "```"
