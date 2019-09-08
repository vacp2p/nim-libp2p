## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Small debug module that's only runs in non release builds.
## It's inspired by the Nodejs ``debug`` module which allows printing 
## colorized output based on matched patterns. This module is powered 
## by the standard ``nre`` module and as such it supports the same set 
## of regexp expressions.
##
## The output is controled through two environment variables ``DEBUG``
## and ``DEBUG_COLOR``. By default, it will print everything to stderr
## but if only some output is of interested, ``DEBUG`` accepts a coma
## separated list of regexp expressions to match the output against.
## Each match gets assigned a different color to help differentiate 
## the output lines.
##
## Colorization is done with 256 ANSI colors, and each run gets a random
## color, if more than one match is specified, each one gets a random color
## to disable this behavior use ``DEBUG_COLOR`` with a valid ANSI color code.
## This will also disable individual colorization for each matched line.
## 

when not defined(release):
  import random, 
         tables, 
         nre, 
         strutils, 
         times, 
         terminal, 
         sequtils,
         os

  type
    Match = object
      pattern: Regex
      color: string

  # if isTrueColorSupported():
  #   system.addQuitProc(resetAttributes)
  #   enableTrueColors()

  var context {.threadvar.} : OrderedTableRef[string, Match]
  proc initDebugCtx() = 
    let debugout = getEnv("DEBUG", ".*")
    let debugColor = getEnv("DEBUG_COLOR")
    let isDebugColor = debugColor.len > 0
    context = newOrderedTable[string, Match]()
    var patrns: seq[string] = @[]
    patrns = debugout.split(re"[,\s]").filterIt(it.len > 0)

    randomize()
    for p in patrns:
      context[p] = Match(pattern: re(p), color: if isDebugColor: debugColor else: $rand(0..272)) # 256 ansi colors

  proc doDebug(data: string, line: string): void {.gcsafe.} = 
    if isNil(context):
      initDebugCtx()
    for m in context.values:
      if data.contains(m.pattern):
        stderr.writeLine("\u001b[38;5;" & m.color & "m " & alignLeft(line & data, 4) & "\e[0m")
        return

  template debug*(data: string) = 
    let module = instantiationInfo()
    let line = "$# $#:$# - " % 
                  [now().format("yyyy-MM-dd HH:mm:ss:fffffffff"), 
                  module.filename[0..^5], 
                  $module.line]
    doDebug(data, line)
else:
  template debug*(data: string) = discard