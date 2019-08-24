## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import sequtils, strutils
import chronos
import connection, varint, vbuffer

const MsgSize* = 64*1024
const Codec* = "/multistream/1.0.0"
const MultiCodec* = "\x19" & Codec & "\n"
const Na = "\x3na\n"
const Ls = "\x3ls\n"

type 
  MultisteamSelectException = object of CatchableError

  Handler* = proc (conn: Connection, proto: string): Future[void]
  Matcher* = proc (proto: string): bool

  HandlerHolder* = object
    proto: string
    handler: Handler
    match: Matcher

  MultisteamSelect* = ref object of RootObj
    handlers*: seq[HandlerHolder]
    codec*: string
    na*: string
    ls*: string

proc newMultistream*(): MultisteamSelect =
  new result
  result.codec = MultiCodec
  result.ls = Ls
  result.na = Na

proc select*(m: MultisteamSelect, conn: Connection, proto: string = ""): Future[bool] {.async.} = 
  ## select a remote protocol
  ## TODO: select should support a list of protos to be selected

  await conn.write(m.codec) # write handshake
  if proto.len() > 0: 
    await conn.writeLp(proto) # select proto

  var ms = cast[string](await conn.readLp())
  ms.removeSuffix("\n")
  if ms != Codec:
    return false

  if proto.len() <= 0:
    return true

  ms = cast[string](await conn.readLp())
  ms.removeSuffix("\n")
  result = ms == proto

proc list*(m: MultisteamSelect, conn: Connection): Future[seq[string]] {.async.} =
  ## list remote protos requests on connection
  if not (await m.select(conn)):
    return

  var list = newSeq[string]()
  let ms = cast[string](await conn.readLp())
  for s in ms.split("\n"):
    list.add(s)

  result = list

proc handle*(m: MultisteamSelect, conn: Connection) {.async.} =
  ## handle requests on connection
  if not (await m.select(conn)):
    return

  while not conn.closed:
    var ms = cast[string](await conn.readLp())
    ms.removeSuffix("\n")
    if ms.len() <= 0:
      await conn.write(m.na)

    if m.handlers.len() == 0:
      await conn.write(m.na)
      continue

    case ms:
      of "ls": 
        for h in m.handlers:
          await conn.writeLp(h.proto & "\n")
      else: 
        for h in m.handlers:
          if (not isNil(h.match) and h.match(ms)) or ms == h.proto:
            await h.handler(conn, ms)
            return
          else:
            await conn.write(m.na)

proc addHandler*(m: MultisteamSelect, 
                 proto: string, 
                 handler: Handler, 
                 matcher: Matcher = nil) = 
  ## register a handler for the protocol
  m.handlers.add(HandlerHolder(proto: proto, 
                               handler: handler, 
                               match: matcher))
