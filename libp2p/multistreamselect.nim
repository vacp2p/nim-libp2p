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
const MultiCodec* = Codec & "\n"
const Na = "na\n"
const Ls = "ls\n"

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
    codec*: seq[byte]
    na*: seq[byte]
    ls*: seq[byte]

proc lp*(data: string, s: var seq[byte]): int =
  var buf = initVBuffer(s)
  buf.writeSeq(data)
  buf.finish()
  s = buf.buffer

proc newMultistream*(): MultisteamSelect =
  new result
  result.codec = newSeq[byte]()
  discard lp(MultiCodec, result.codec)

  result.na = newSeq[byte]()
  discard lp(Na, result.na)

  result.ls = newSeq[byte]()
  discard lp(Ls, result.ls)

proc select*(m: MultisteamSelect, conn: Connection, proto: string): Future[bool] {.async.} = 
  ## select a remote protocol
  await conn.write(m.codec) # write handshake
  await conn.writeLp(proto) # select proto
  var ms = cast[string](await conn.readLp())
  echo MultiCodec
  if ms != MultiCodec:
    raise newException(MultisteamSelectException, 
                       "Error: invalid multistream codec " & "\"" & ms & "\"")

  var msProto = cast[string](await conn.readLp())
  msProto.removeSuffix("\n")
  result = msProto == proto

proc ls*(m: MultisteamSelect): Future[seq[string]] {.async.} = 
  ## list all remote protocol strings
  discard

# proc handle*(m: MultisteamSelect, conn: Connection) {.async.} =
#   ## handle requests on connection
#   await conn.write(m.codec)

#   let ms = await conn.readLine(0, "\n")
#   if ms != MultiCodec:
#     raise newException(MultisteamSelectException, 
#                        "Error: invalid multistream codec " & "\"" & $ms & "\"")
  
#   let ms = await conn.readLine(0, "\n")


proc addHandler*(m: MultisteamSelect, 
                 proto: string, 
                 handler: Handler, 
                 matcher: Matcher = nil) = 
  ## register a handler for the protocol
  m.handlers.add(HandlerHolder(proto: proto, 
                               handler: handler, 
                               match: matcher))
