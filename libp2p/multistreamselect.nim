## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import sequtils
import chronos
import connection, varint, vbuffer

const Codec* = "/multistream/1.0.0"
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

proc lp*(data: string): seq[byte] =
  var buf = initVBuffer(newSeq[byte](256))
  buf.writeSeq(data)
  var lpData = newSeq[byte](buf.length)
  if buf.readSeq(lpData) < 0:
    raise newException(MultisteamSelectException, "Error: failed to lenght prefix")
  result = lpData

proc newMultistream*(): MultisteamSelect =
  new result
  result.codec = lp(Codec & "\n")
  result.na = lp(Na)
  result.ls = lp(Ls)

proc select*(m: MultisteamSelect, conn: Connection, proto: string): Future[bool] {.async.} = 
  ## select a remote protocol
  await conn.write(m.codec)
  await conn.write(lp(proto)) # select proto

  let ms = await conn.readLine(0, "\n")
  if ms != Codec: 
    raise newException(MultisteamSelectException, "Error: invalid multistream codec" & $ms)

  let remote = await conn.readLine(0, "\n")
  result = remote == proto

proc ls*(m: MultisteamSelect): seq[string] {.async.} = 
  ## list all remote protocol strings
  discard

proc handle*(m: MultisteamSelect, conn: Connection) {.async.} =
  ## handle requests on connection
  discard

proc addHandle*(m: MultisteamSelect, 
                proto: string, 
                handler: Handler, 
                matcher: Matcher = nil) = 
  ## register a handler for the protocol
  m.handlers.add(HandlerHolder(proto: proto, 
                               handler: handler, 
                               match: matcher))
