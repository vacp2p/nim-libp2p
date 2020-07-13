## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import strutils
import chronos, chronicles, stew/byteutils
import stream/connection,
       vbuffer,
       protocols/protocol

logScope:
  topics = "multistream"

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
    trace "selecting proto", proto = proto[0]
    await conn.writeLp((proto[0] & "\n")) # select proto

  var s = string.fromBytes((await conn.readLp(1024))) # read ms header
  s.removeSuffix("\n")
  if s != Codec:
    notice "handshake failed", codec = s.toHex()
    return ""

  if proto.len() == 0: # no protocols, must be a handshake call
    return Codec
  else:
    s = string.fromBytes(await conn.readLp(1024)) # read the first proto
    trace "reading first requested proto"
    s.removeSuffix("\n")
    if s == proto[0]:
      trace "successfully selected ", proto = proto[0]
      return proto[0]
    elif proto.len > 1:
      # Try to negotiate alternatives
      let protos = proto[1..<proto.len()]
      trace "selecting one of several protos", protos = protos
      for p in protos:
        trace "selecting proto", proto = p
        await conn.writeLp((p & "\n")) # select proto
        s = string.fromBytes(await conn.readLp(1024)) # read the first proto
        s.removeSuffix("\n")
        if s == p:
          trace "selected protocol", protocol = s
          return s
      return ""
    else:
      # No alternatives, fail
      return ""

proc select*(m: MultistreamSelect,
             conn: Connection,
             proto: string): Future[bool] {.async.} =
  if proto.len > 0:
    return (await m.select(conn, @[proto])) == proto
  else:
    return (await m.select(conn, @[])) == Codec

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
          debug "no handlers for ", protocol = ms
          await conn.write(Na)
  except CancelledError as exc:
    await conn.close()
    raise exc
  except CatchableError as exc:
    trace "exception in multistream", exc = exc.msg
    await conn.close()
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
