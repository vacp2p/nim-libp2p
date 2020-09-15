## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
import std/[os, strutils, times]
import chronicles
import ../libp2p/debugutils

const
  PBCapParserName* = "PBCapParser"
  ## project name string

  PBCapParserMajor*: int = 0
  ## is the major number of PBCapParser' version.

  PBCapParserMinor*: int = 0
  ## is the minor number of PBCapParser' version.

  PBCapParserPatch*: int = 1
  ## is the patch number of PBCapParser' version.

  PBCapParserVersion* = $PBCapParserMajor & "." & $PBCapParserMinor & "." &
                        $PBCapParserPatch
  ## is the version of Nimbus as a string.

  GitRevision = staticExec("git rev-parse --short HEAD").replace("\n") # remove CR

  PBCapParserUsage = """

USAGE:
  pbcap_parser <command> <filename>

COMMANDS:
  dump        Show full hexadecimal dump with ascii symbols of packets
  hex         Show only hexadecimal string of message
"""

let
  PBCapParserCopyright* = "Copyright (c) 2020-" & $(now().utc.year) &
                          " Status Research & Development GmbH"
  PBCapParserHeader* = "$# Version $# [$#: $#, $#]\p$#\p" %
    [PBCapParserName, PBCapParserVersion, hostOS, hostCPU, GitRevision,
     PBCapParserCopyright]

proc parseFile*(pathName: string, dump: bool): string =
  ## Parse `pbcap` file ``pathName``, and return decoded output as string dump.
  ##
  ## If ``pathName`` is relative path, then
  ## ``getHomeDir() / libp2p_dump_dir / pathName`` will be used.
  var res = ""
  let path =
    if isAbsolute(pathName):
      pathName
    else:
      getHomeDir() / libp2p_dump_dir / pathName
  var sdata = string(readFile(path))
  var buffer = cast[seq[byte]](sdata)
  for item in messages(buffer):
    if item.isNone():
      break
    res = res & toString(item.get(), dump)
  res

when isMainModule:
  echo PBCapParserHeader
  if paramCount() < 2:
    echo PBCapParserUsage
    quit 0
  else:
    let cmd = toLowerAscii(paramStr(1))
    if cmd notin ["dump", "hex"]:
      fatal "Unrecognized command found", command = paramStr(1)
      quit 1

    let path =
      if isAbsolute(paramStr(2)):
        paramStr(2)
      else:
        getHomeDir() / libp2p_dump_dir / paramStr(2)

    if not(fileExists(path)):
      fatal "Could not find pbcap file", filename = path
      quit 1

    let dump = if cmd == "dump": true else: false
    try:
      echo parseFile(paramStr(2), dump)
    except:
      fatal "Could not read pbcap file", filename = path
