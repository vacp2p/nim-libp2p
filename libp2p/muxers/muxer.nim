# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos, chronicles
import stew/results
import ../stream/connection,
       ../errors

logScope:
  topics = "libp2p muxer"

const
  DefaultChanTimeout* = 5.minutes

type
  MuxerError* = object of LPError
  TooManyChannels* = object of MuxerError

  StreamHandler* = proc(conn: Connection): Future[void] {.gcsafe, raises: [].}
  MuxerHandler* = proc(muxer: Muxer): Future[void] {.gcsafe, raises: [].}

  Muxer* = ref object of RootObj
    streamHandler*: StreamHandler
    handler*: Future[void]
    connection*: Connection

  # user provider proc that returns a constructed Muxer
  MuxerConstructor* = proc(conn: Connection, direction: Opt[Direction] = Opt.none(Direction)): Muxer {.gcsafe, closure, raises: [].}

  # this wraps a creator proc that knows how to make muxers
  MuxerProvider* = object
    newMuxer*: MuxerConstructor
    codec*: string

func shortLog*(m: Muxer): auto =
  if isNil(m): "nil"
  else: shortLog(m.connection)
chronicles.formatIt(Muxer): shortLog(it)

# muxer interface
method newStream*(m: Muxer, name: string = "", lazy: bool = false):
  Future[Connection] {.base, async, gcsafe.} = discard
method close*(m: Muxer) {.base, async, gcsafe.} =
  if not isNil(m.connection):
    await m.connection.close()
method handle*(m: Muxer): Future[void] {.base, async, gcsafe.} = discard

proc new*(
  T: typedesc[MuxerProvider],
  creator: MuxerConstructor,
  codec: string): T {.gcsafe.} =

  let muxerProvider = T(newMuxer: creator, codec: codec)
  muxerProvider

method getStreams*(m: Muxer): seq[Connection] {.base.} = doAssert false, "not implemented"
