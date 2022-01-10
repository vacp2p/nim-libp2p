## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import chronos, chronicles
import ../protocols/protocol,
       ../stream/connection,
       ../errors

logScope:
  topics = "libp2p muxer"

const
  DefaultChanTimeout* = 5.minutes

type
  MuxerError* = object of LPError

  StreamHandler* = proc(conn: Connection): Future[void] {.gcsafe, raises: [Defect].}
  MuxerHandler* = proc(muxer: Muxer): Future[void] {.gcsafe, raises: [Defect].}

  Muxer* = ref object of RootObj
    streamHandler*: StreamHandler
    connection*: Connection

  # user provider proc that returns a constructed Muxer
  MuxerConstructor* = proc(conn: Connection): Muxer {.gcsafe, closure, raises: [Defect].}

  # this wraps a creator proc that knows how to make muxers
  MuxerProvider* = ref object of LPProtocol
    newMuxer*: MuxerConstructor
    streamHandler*: StreamHandler # triggered every time there is a new stream, called for any muxer instance
    muxerHandler*: MuxerHandler # triggered every time there is a new muxed connection created

func shortLog*(m: Muxer): auto = shortLog(m.connection)
chronicles.formatIt(Muxer): shortLog(it)

# muxer interface
method newStream*(m: Muxer, name: string = "", lazy: bool = false):
  Future[Connection] {.base, async, gcsafe.} = discard
method close*(m: Muxer) {.base, async, gcsafe.} = discard
method handle*(m: Muxer): Future[void] {.base, async, gcsafe.} = discard

proc new*(
  T: typedesc[MuxerProvider],
  creator: MuxerConstructor,
  codec: string): T {.gcsafe.} =

  let muxerProvider = T(newMuxer: creator)
  muxerProvider.codec = codec
  muxerProvider.init()
  muxerProvider

method init(c: MuxerProvider) =
  proc handler(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    trace "starting muxer handler", proto=proto, conn
    try:
      let
        muxer = c.newMuxer(conn)

      if not isNil(c.streamHandler):
        muxer.streamHandler = c.streamHandler

      var futs = newSeq[Future[void]]()
      futs &= muxer.handle()

      # finally await both the futures
      if not isNil(c.muxerHandler):
        await c.muxerHandler(muxer)
        when defined(libp2p_agents_metrics):
          conn.shortAgent = muxer.connection.shortAgent

      checkFutures(await allFinished(futs))
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in muxer handler", exc = exc.msg, conn, proto
    finally:
      await conn.close()

  c.handler = handler
