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
  ## Comma-separated list of muxers to enable at compile time.
  ## Supported values: ``mplex``, ``yamux``.
  ## Defaults to ``"mplex,yamux"`` (all muxers enabled).

proc initSupportedMuxers(list: static string): set[uint8] =
  var res: set[uint8]
  for item in list.split({',', ';', '|'}):
    let name = strip(item)
    if cmpIgnoreCase(name, "mplex") == 0:
      res.incl(0'u8)
    elif cmpIgnoreCase(name, "yamux") == 0:
      res.incl(1'u8)
  if len(res) == 0:
    res = {0'u8, 1'u8}
  res

const SupportedMuxersSet = initSupportedMuxers(libp2p_muxers)

const
  MplexEnabled* = 0'u8 in SupportedMuxersSet
    ## ``true`` when mplex is enabled via ``-d:libp2p_muxers``.
  YamuxEnabled* = 1'u8 in SupportedMuxersSet
    ## ``true`` when yamux is enabled via ``-d:libp2p_muxers``.

when not MplexEnabled and not YamuxEnabled:
  {.error: "At least one muxer must be enabled. Use -d:libp2p_muxers=mplex,yamux".}
