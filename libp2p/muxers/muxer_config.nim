# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Compile-time muxer selection for nim-libp2p.
##
## Use ``-d:libp2p_muxers=<comma-separated list>`` to select which stream
## multiplexers are compiled into the application. Supported values are
## ``mplex`` and ``yamux`` (case-insensitive, separator may be ``,``, ``;``,
## or ``|``).
##
## Example – compile with only mplex (excludes yamux):
##
## .. code-block:: bash
##   nim c -d:libp2p_muxers=mplex myapp.nim
##
## Example – compile with only yamux (excludes mplex):
##
## .. code-block:: bash
##   nim c -d:libp2p_muxers=yamux myapp.nim

{.push raises: [].}

from strutils import split, strip, cmpIgnoreCase

const libp2p_muxers* {.strdefine.} = "mplex,yamux"

func muxerEnabled(list: static string, muxer: static string): bool =
  for item in list.split({',', ';', '|'}):
    if cmpIgnoreCase(item.strip(), muxer) == 0:
      return true

func validMuxerList(list: static string): bool =
  for item in list.split({',', ';', '|'}):
    let name = item.strip()
    if name.len == 0:
      continue

    if cmpIgnoreCase(name, "mplex") != 0 and cmpIgnoreCase(name, "yamux") != 0:
      return false

  true

when not validMuxerList(libp2p_muxers):
  {.error: "Unsupported muxer in -d:libp2p_muxers. Supported values: mplex,yamux".}

const
  MplexEnabled* = muxerEnabled(libp2p_muxers, "mplex")
  YamuxEnabled* = muxerEnabled(libp2p_muxers, "yamux")

when not (MplexEnabled or YamuxEnabled):
  {.error: "At least one muxer must be enabled. Use -d:libp2p_muxers=mplex,yamux".}
