# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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
    {.gcsafe, raises: [].}

  LPProtocol* = ref object of RootObj
    codecs*: seq[string]
    handler*: LPProtoHandler ## this handler gets invoked by the protocol negotiator
    started*: bool
    maxIncomingStreams: Opt[int]

method init*(p: LPProtocol) {.base, gcsafe.} = discard

method start*(
    p: LPProtocol) {.async: (raises: [CancelledError], raw: true), base.} =
  let fut = newFuture[void]()
  fut.complete()
  p.started = true
  fut

method stop*(p: LPProtocol) {.async: (raises: [], raw: true), base.} =
  let fut = newFuture[void]()
  fut.complete()
  p.started = false
  fut

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
  handler: LPProtoHandler,
  maxIncomingStreams: Opt[int] | int = Opt.none(int)): T =
  T(
    codecs: codecs,
    handler: handler,
    maxIncomingStreams:
      when maxIncomingStreams is int: Opt.some(maxIncomingStreams)
      else: maxIncomingStreams
  )
