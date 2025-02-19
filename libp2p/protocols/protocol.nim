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

const DefaultMaxIncomingStreams* = 10

type
  LPProtoHandler* =
    proc(conn: Connection, proto: string): Future[void] {.async: (raises: []).}

  LPProtocol* = ref object of RootObj
    codecs*: seq[string]
    handlerImpl: LPProtoHandler ## invoked by the protocol negotiator
    started*: bool
    maxIncomingStreams: Opt[int]

method init*(p: LPProtocol) {.base, gcsafe.} =
  discard

method start*(p: LPProtocol) {.async: (raises: [CancelledError], raw: true), base.} =
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

# Callbacks that are annotated with `{.async: (raises).}` explicitly
# document the types of errors that they may raise, but are not compatible
# with `LPProtoHandler` and need to use a custom `proc` type.
# They are internally wrapped into a `LPProtoHandler`, but still allow the
# compiler to check that their `{.async: (raises).}` annotation is correct.
# https://github.com/nim-lang/Nim/issues/23432
func `handler=`*[E](
    p: LPProtocol,
    handler: proc(conn: Connection, proto: string): InternalRaisesFuture[void, E],
) =
  proc wrap(conn: Connection, proto: string): Future[void] {.async.} =
    await handler(conn, proto)

  p.handlerImpl = wrap

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

proc new*[E](
    T: type LPProtocol,
    codecs: seq[string],
    handler: proc(conn: Connection, proto: string): InternalRaisesFuture[void, E],
    maxIncomingStreams: Opt[int] | int = Opt.none(int),
): T =
  proc wrap(conn: Connection, proto: string): Future[void] {.async.} =
    await handler(conn, proto)

  T.new(codec, wrap, maxIncomingStreams)
