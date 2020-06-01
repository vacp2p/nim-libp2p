## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import strutils, stew/byteutils
import chronos, chronicles
import connection,
       vbuffer,
       errors,
       protocols/protocol

logScope:
  topic = "Multistream"

const
  MsgSize* = 64*1024
  Codec* = "/multistream/1.0.0"

  MSCodec* = "\x13" & Codec & "\n"
  Na* = "\x03na\n"
  Ls* = "\x03ls\n"

type
  Matcher* = proc (proto: string): bool {.gcsafe.}

  HandlerHolder* = object
    proto*: string
    protocol*: LPProtocol
    match*: Matcher

  MultistreamSelect* = ref object of RootObj
    handlers*: seq[HandlerHolder]
    codec*: string

  MultistreamHandshakeException* = object of CatchableError

proc newMultistreamHandshakeException*(): ref CatchableError {.inline.} =
  result = newException(MultistreamHandshakeException,
    "could not perform multistream handshake")

proc newMultistream*(): MultistreamSelect =
  new result
  result.codec = MSCodec

proc select*(m: MultistreamSelect,
             conn: Connection,
             proto: seq[string]):
             Future[string] {.async.} =
  trace "initiating handshake", codec = m.codec
  ## select a remote protocol
  await conn.write(m.codec) # write handshake
  if proto.len() > 0:
    trace "selecting proto", proto = proto
    await conn.writeLp((proto[0] & "\n")) # select proto

  result = cast[string]((await conn.readLp(1024))) # read ms header
  result.removeSuffix("\n")
  if result != Codec:
    notice "handshake failed", codec = result.toHex()
    raise newMultistreamHandshakeException()

  if proto.len() == 0: # no protocols, must be a handshake call
    return

  result = string.fromBytes(await conn.readLp(1024)) # read the first proto
  trace "reading first requested proto"
  result.removeSuffix("\n")
  if result == proto[0]:
    trace "successfully selected ", proto = proto
    return

  let protos = proto[1..<proto.len()]
  trace "selecting one of several protos", protos = protos
  for p in protos:
    trace "selecting proto", proto = p
    await conn.writeLp((p & "\n")) # select proto
    result = string.fromBytes(await conn.readLp(1024)) # read the first proto
    result.removeSuffix("\n")
    if result == p:
      trace "selected protocol", protocol = result
      break

proc select*(m: MultistreamSelect,
             conn: Connection,
             proto: string): Future[bool] {.async.} =
  if proto.len > 0:
    result = (await m.select(conn, @[proto])) == proto
  else:
    result = (await m.select(conn, @[])) == Codec

proc select*(m: MultistreamSelect, conn: Connection): Future[bool] =
  m.select(conn, "")

proc list*(m: MultistreamSelect,
           conn: Connection): Future[seq[string]] {.async.} =
  ## list remote protos requests on connection
  if not await m.select(conn):
    return

  await conn.write(Ls) # send ls

  var list = newSeq[string]()
  let ms = string.fromBytes(await conn.readLp(1024))
  for s in ms.split("\n"):
    if s.len() > 0:
      list.add(s)

  result = list

proc handle*(m: MultistreamSelect, conn: Connection) {.async, gcsafe.} =
  trace "handle: starting multistream handling"
  try:
    while not conn.closed:
      var ms = string.fromBytes(await conn.readLp(1024))
      ms.removeSuffix("\n")

      trace "handle: got request for ", ms
      if ms.len() <= 0:
        trace "handle: invalid proto"
        await conn.write(Na)

      if m.handlers.len() == 0:
        trace "handle: sending `na` for protocol ", protocol = ms
        await conn.write(Na)
        continue

      case ms:
        of "ls":
          trace "handle: listing protos"
          var protos = ""
          for h in m.handlers:
            protos &= (h.proto & "\n")
          await conn.writeLp(protos)
        of Codec:
          await conn.write(m.codec)
        else:
          for h in m.handlers:
            if (not isNil(h.match) and h.match(ms)) or ms == h.proto:
              trace "found handler for", protocol = ms
              await conn.writeLp((h.proto & "\n"))
              await h.protocol.handler(conn, ms)
              return
          warn "no handlers for ", protocol = ms
          await conn.write(Na)
  except CatchableError as exc:
    trace "exception in multistream", exc = exc.msg
  finally:
    trace "leaving multistream loop"

proc addHandler*[T: LPProtocol](m: MultistreamSelect,
                                codec: string,
                                protocol: T,
                                matcher: Matcher = nil) =
  ## register a protocol
  # TODO: This is a bug in chronicles,
  # it break if I uncomment this line.
  # Which is almost the same as the
  # one on the next override of addHandler
  #
  # trace "registering protocol", codec = codec
  m.handlers.add(HandlerHolder(proto: codec,
                               protocol: protocol,
                               match: matcher))

proc addHandler*[T: LPProtoHandler](m: MultistreamSelect,
                                    codec: string,
                                    handler: T,
                                    matcher: Matcher = nil) =
  ## helper to allow registering pure handlers

  trace "registering proto handler", codec = codec
  let protocol = new LPProtocol
  protocol.codec = codec
  protocol.handler = handler

  m.handlers.add(HandlerHolder(proto: codec,
                               protocol: protocol,
                               match: matcher))
