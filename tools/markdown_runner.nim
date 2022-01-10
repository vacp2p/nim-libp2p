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
  if startOfBlock == -1: break

  let endOfBlock = contents.find(endDelim, start = startOfBlock + startDelim.len)
  if endOfBlock == -1:
    quit "Unfinished block!"

  let code = contents[startOfBlock + startDelim.len .. endOfBlock]

  echo code

  index = endOfBlock + endDelim.len
