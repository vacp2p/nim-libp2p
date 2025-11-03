# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import os, osproc, streams, strutils
import parseutils

let contents =
  if paramCount() > 0:
    readFile(paramStr(1))
  else:
    stdin.readAll()
var index = 0

const startDelim = "```nim\n"
const endDelim = "\n```"
while true:
  let startOfBlock = contents.find(startDelim, start = index)
  if startOfBlock == -1:
    break

  let endOfBlock = contents.find(endDelim, start = startOfBlock + startDelim.len)
  if endOfBlock == -1:
    quit "Unfinished block!"

  let code = contents[startOfBlock + startDelim.len .. endOfBlock]

  echo code

  index = endOfBlock + endDelim.len
