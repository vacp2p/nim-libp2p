## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Small debug module that's enabled through a ``-d:debugout``
## flag. It's inspired by the Nodejs ``debug`` module that
## allows printing colorized output based on patterns. This 
## module is powered by the standard ``nre`` module and as such
## it supports the same set of regexp expressions.
##
## To enable debug output, pass the ``debugout`` flag during build
## time with ``-d`` flag. In addition, the debugout flag takes a comma
## separated list of patters that will narow the debug output to
## only those matched by the patterns. By default however, all
## debug statements are outputed to the stderr.

when defined(debugout) and not defined(release):
  import random, 
         tables, 
         nre, 
         strutils, 
         times, 
         terminal, 
         sequtils

  const debugout {.strdefine.}: string = ".*"

  type
    Match = object
      pattern: Regex
      color: string
    
  var matches: OrderedTable[string, Match] = initOrderedTable[string, Match]()
  var patrns = @[".*"]
  if debugout != "true":
    patrns = debugout.split(re"[,\s]").filterIt(it.len > 0)

  randomize()
  for p in patrns:
    matches[p] = Match(pattern: re(p), color: $rand(0..272)) # 256 ansi colors
  # matches["*"] = Match(pattern: re(".*"), color: $rand(0..272)) # 256 ansi colors

  if isTrueColorSupported():
    system.addQuitProc(resetAttributes)
    enableTrueColors()

  proc doDebug(data: string): void {.gcsafe.} = 
    for m in matches.values:
      if data.match(m.pattern).isSome:
        stderr.writeLine("\u001b[38;5;" & m.color & "m " & alignLeft(data, 4) & "\e[0m")
        return

  template debug*(data: string) = 
    let module = instantiationInfo()
    let line = "$# $#:$# - $#" % 
                  [now().format("yyyy-MM-dd HH:mm:ss:fffffffff"), 
                  module.filename[0 .. ^5], 
                  $module.line,
                  data]
    doDebug(line)

else:
  template debug*(data: string) = discard