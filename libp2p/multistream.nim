## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import strutils
import chronos, chronicles
import vbuffer,
       protocols/protocol,
       streams/[connection,
                stream,
                pushable,
                asynciters,
                lenprefixed]

logScope:
  topic = "Multistream"

const
  MsgSize* = 64 * 1024
  Codec* = "/multistream/1.0.0"

  Na* = "na"
  Ls* = "ls"

type
  Matcher* = proc (proto: string): bool {.gcsafe.}

  HandlerHolder* = object
    proto*: string
    protocol*: LPProtocol
    match*: Matcher

  MultistreamSelect* = object
    handlers*: seq[HandlerHolder]
    codec*: string
    na: string
    ls: string

  MultistreamHandshakeException* = object of CatchableError

proc newMultistreamHandshakeException*(): ref Exception {.inline.} =
  result = newException(MultistreamHandshakeException,
    "could not perform multistream handshake")

proc append(item: Future[seq[byte]]): Future[seq[byte]] {.async.} =
  result = await item
  result.add(byte('\n'))

var appendNl: Through[seq[byte]] = proc (i: Source[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
  return iterator(): Future[seq[byte]] {.closure.} =
    for item in i:
      yield append(item)

proc strip(item: Future[seq[byte]]): Future[seq[byte]] {.async.} =
  result = await item
  if result[^1] == byte('\n'):
    result.setLen(result.high)

var stripNl: Through[seq[byte]] = proc (i: Source[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
  return iterator(): Future[seq[byte]] {.closure.} =
    for item in i:
      yield strip(item)

proc init*(M: type[MultistreamSelect]): MultistreamSelect =
  M(codec: Codec, ls: Ls, na: Na)

proc select*(m: MultistreamSelect,
             conn: Connection,
             protos: seq[string]):
             Future[string] {.async.} =
  trace "initiating handshake", codec = m.codec
  var pushable = Pushable[seq[byte]].init() # pushable source
  var lp = LenPrefixed.init()

  var sink = pipe(pushable,
                  appendNl,
                  lp.encoder,
                  conn)

  let source = pipe(conn,
                    lp.decoder,
                    stripNl)

  # handshake first
  await pushable.push(cast[seq[byte]](m.codec))

  # (common optimization) if we've got
  # protos send the first one out immediately
  # without waiting for the handshake response
  if protos.len > 0:
    await pushable.push(cast[seq[byte]](protos[0]))

  # check for handshake result
  result = cast[string](await source())
  if result != m.codec:
    error "handshake failed", codec = result.toHex()
    raise newMultistreamHandshakeException()

  # write out first protocol without waiting for response
  var i = 0
  while i < protos.len:
    # first read because we've the outstanding requirest above
    trace "reading requested proto"
    for chunk in source:
      result = cast[string](await chunk)

    if result == protos[i]:
      trace "succesfully selected ", proto = proto
      break

    if i > 0:
      trace "selecting proto", proto = proto
      await pushable.push(cast[seq[byte]](protos[i])) # select proto
    i.inc()
  await sink

proc select*(m: MultistreamSelect,
             conn: Connection,
             proto: string): Future[bool] {.async.} =
  if proto.len > 0:
    result = (await m.select(conn, @[proto])) == proto
  else:
    result = (await m.select(conn, @[])) == Codec

proc select*(m: MultistreamSelect, conn: Connection): Future[bool] =
  m.select(conn, "")

# proc list*(m: MultistreamSelect,
#            conn: Connection): Future[seq[string]] {.async.} =
#   ## list remote protos requests on connection
#   if not await m.select(conn):
#     return

#   await conn.write(m.ls) # send ls

#   var list = newSeq[string]()
#   let ms = cast[string]((await conn.readLp()))
#   for s in ms.split("\n"):
#     if s.len() > 0:
#       list.add(s)

#   result = list

# proc handle*(m: MultistreamSelect, conn: Connection) {.async, gcsafe.} =
#   trace "handle: starting multistream handling"
#   try:
#     while not conn.closed:
#       var ms = cast[string]((await conn.readLp()))
#       ms.removeSuffix("\n")

#       trace "handle: got request for ", ms
#       if ms.len() <= 0:
#         trace "handle: invalid proto"
#         await conn.write(m.na)

#       if m.handlers.len() == 0:
#         trace "handle: sending `na` for protocol ", protocol = ms
#         await conn.write(m.na)
#         continue

#       case ms:
#         of "ls":
#           trace "handle: listing protos"
#           var protos = ""
#           for h in m.handlers:
#             protos &= (h.proto & "\n")
#           await conn.writeLp(protos)
#         of Codec:
#           await conn.write(m.codec)
#         else:
#           for h in m.handlers:
#             if (not isNil(h.match) and h.match(ms)) or ms == h.proto:
#               trace "found handler for", protocol = ms
#               await conn.writeLp((h.proto & "\n"))
#               try:
#                 await h.protocol.handler(conn, ms)
#                 return
#               except CatchableError as exc:
#                 warn "exception while handling", msg = exc.msg
#                 return
#           warn "no handlers for ", protocol = ms
#           await conn.write(m.na)
#   except CatchableError as exc:
#     trace "Exception occurred", exc = exc.msg
#   finally:
#     trace "leaving multistream loop"

# proc addHandler*[T: LPProtocol](m: MultistreamSelect,
#                                 codec: string,
#                                 protocol: T,
#                                 matcher: Matcher = nil) =
#   ## register a protocol
#   # TODO: This is a bug in chronicles,
#   # it break if I uncoment this line.
#   # Which is almost the same as the
#   # one on the next override of addHandler
#   #
#   # trace "registering protocol", codec = codec
#   m.handlers.add(HandlerHolder(proto: codec,
#                                protocol: protocol,
#                                match: matcher))

# proc addHandler*[T: LPProtoHandler](m: MultistreamSelect,
#                                     codec: string,
#                                     handler: T,
#                                     matcher: Matcher = nil) =
#   ## helper to allow registering pure handlers

#   trace "registering proto handler", codec = codec
#   let protocol = new LPProtocol
#   protocol.codec = codec
#   protocol.handler = handler

#   m.handlers.add(HandlerHolder(proto: codec,
#                                protocol: protocol,
#                                match: matcher))
