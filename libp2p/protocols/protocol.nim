# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronos, stew/results
import ../stream/connection

export results

const
  DefaultMaxIncomingStreams* = 10

type
  LPProtoHandler* = proc (
    conn: Connection,
    proto: string):
    Future[void]
    {.gcsafe, raises: [Defect].}

  LPProtocol* = ref object of RootObj
    codecs*: seq[string]
    handler*: LPProtoHandler ## this handler gets invoked by the protocol negotiator
    started*: bool
    maxIncomingStreams: Opt[int]

method init*(p: LPProtocol) {.base, gcsafe.} = discard
method start*(p: LPProtocol) {.async, base.} = p.started = true
method stop*(p: LPProtocol) {.async, base.} = p.started = false

proc maxIncomingStreams*(p: LPProtocol): int =
  p.maxIncomingStreams.get(DefaultMaxIncomingStreams)

proc `maxIncomingStreams=`*(p: LPProtocol, val: int) =
  p.maxIncomingStreams = Opt.some(val)

func codec*(p: LPProtocol): string =
  assert(p.codecs.len > 0, "Codecs sequence was empty!")
  p.codecs[0]

func `codec=`*(p: LPProtocol, codec: string) =
  # always insert as first codec
  # if we use this abstraction
  p.codecs.insert(codec, 0)

proc new*(
  T: type LPProtocol,
  codecs: seq[string],
  handler: LPProtoHandler,  # default(Opt[int]) or Opt.none(int) don't work on 1.2
  maxIncomingStreams: Opt[int] | int = Opt[int]()): T =
  T(
    codecs: codecs,
    handler: handler,
    maxIncomingStreams:
      when maxIncomingStreams is int: Opt.some(maxIncomingStreams)
      else: maxIncomingStreams
  )
