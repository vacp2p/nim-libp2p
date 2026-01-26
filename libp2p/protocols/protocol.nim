# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.push raises: [].}

import chronos, results
import ../stream/connection

export results

const DefaultMaxIncomingStreams* = 10

type
  LPProtoHandler* = proc(conn: Connection, proto: string): Future[void] {.
    async: (raises: [CancelledError])
  .}

  LPProtocol* = ref object of RootObj
    codecs*: seq[string]
    handlerImpl: LPProtoHandler ## invoked by the protocol negotiator
    started*: bool
    maxIncomingStreams: Opt[int]

method init*(p: LPProtocol) {.base, gcsafe.} =
  discard

method start*(p: LPProtocol) {.base, async: (raises: [CancelledError], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  p.started = true
  fut

method stop*(p: LPProtocol) {.base, async: (raises: [], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  p.started = false
  fut

proc maxIncomingStreams*(p: LPProtocol): int =
  p.maxIncomingStreams.get(DefaultMaxIncomingStreams)

proc `maxIncomingStreams=`*(p: LPProtocol, val: int) =
  p.maxIncomingStreams = Opt.some(val)

func codec*(p: LPProtocol): string =
  doAssert(p.codecs.len > 0, "Codecs sequence was empty!")
  p.codecs[0]

func `codec=`*(p: LPProtocol, codec: string) =
  # always insert as first codec
  # if we use this abstraction
  p.codecs.insert(codec, 0)

template `handler`*(p: LPProtocol): LPProtoHandler =
  p.handlerImpl

template `handler`*(p: LPProtocol, conn: Connection, proto: string): Future[void] =
  p.handlerImpl(conn, proto)

func `handler=`*(p: LPProtocol, handler: LPProtoHandler) =
  p.handlerImpl = handler

proc new*(
    T: type LPProtocol,
    codecs: seq[string],
    handler: LPProtoHandler,
    maxIncomingStreams: Opt[int] | int = Opt.none(int),
): T =
  T(
    codecs: codecs,
    handlerImpl: handler,
    maxIncomingStreams:
      when maxIncomingStreams is int:
        Opt.some(maxIncomingStreams)
      else:
        maxIncomingStreams,
  )
