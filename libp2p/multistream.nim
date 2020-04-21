## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import strutils, sequtils
import chronos, chronicles, stew/byteutils
import vbuffer,
       protocols/protocol,
       streams/[connection,
                stream,
                pushable,
                asynciters,
                lenprefixed,
                utils]

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
    codec*: seq[byte]
    na*: seq[byte]
    ls*: seq[byte]
    lp: LenPrefixed

  MultistreamHandshakeException* = object of CatchableError

proc newMultistreamHandshakeException*(): ref Exception {.inline.} =
  result = newException(MultistreamHandshakeException,
    "could not perform multistream handshake")

proc init*(M: type[MultistreamSelect]): MultistreamSelect =
  M(codec: toSeq(Codec).mapIt( it.byte ),
    ls: Ls.toBytes(),
    na: Na.toBytes(),
    lp: LenPrefixed.init())

proc select*(m: MultistreamSelect,
             conn: Connection,
             protos: seq[string]):
             Future[string] {.async.} =
  trace "initiating handshake", codec = Codec,
                                proto = protos
  var pushable = BytePushable.init() # pushable source
  var source = pipe(pushable,
                    appendNl(),
                    m.lp.encoder,
                    conn.toThrough,
                    m.lp.decoder,
                    stripNl())

  # handshake first
  await pushable.push(m.codec)

  # (common optimization) if we've got
  # protos send the first one out immediately
  # without waiting for the handshake response
  if protos.len > 0:
    await pushable.push(protos[0].toBytes())

  # check for handshake result
  var res = await source()
  if res != m.codec:
    error "handshake failed", codec = result.toHex()
    raise newMultistreamHandshakeException()

  if protos.len == 0:
    return Codec

  # write out first protocol without waiting for response
  for i in 0..protos.high:
    # first read because we've the outstanding requirest above
    trace "reading requested proto", proto = protos[i]
    res = await source()
    echo "RES ", res

    var protoBytes = protos[i].toBytes()
    if res == protoBytes:
      trace "succesfully selected ", proto = protos[i]
      return protos[i]

    if i > 0:
      trace "selecting proto", proto = protos[i]
      await pushable.push(protoBytes) # select proto

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
    trace "unable to list, handshake failed"
    return

  var pushable = BytePushable.init()
  var source = pipe(pushable,
                    appendNl(),
                    m.lp.encoder,
                    conn.toThrough,
                    m.lp.decoder,
                    stripNl())

  await pushable.push(m.ls) # send ls

  var list = newSeq[string]()
  var msg = string.fromBytes((await source()))
  for s in msg.split("\n"):
    if s.len() > 0:
      list.add(s)

  result = list

proc handle*(m: MultistreamSelect, conn: Connection) {.async, gcsafe.} =
  trace "starting multistream handling"

  var pushable = BytePushable.init()
  try:
    var source = pipe(pushable,
                      appendNl(),
                      m.lp.encoder,
                      conn.toThrough,
                      m.lp.decoder,
                      stripNl())

    for chunk in source:
      var msg = string.fromBytes((await chunk))
      trace "got request for ", msg
      if msg.len <= 0:
        trace "empty request, handler EOF"
        break

      if m.handlers.len() == 0:
        trace "sending `na` for protocol ", protocol = msg
        await pushable.push(m.na)
        continue

      case msg:
        of Ls:
          trace "listing protos"
          var protos: string
          for i in 0..m.handlers.high:
            protos &= m.handlers[i].proto
            if i < m.handlers.high:
              protos &= "\n"

          await pushable.push(protos.toBytes())
        of Codec:
          trace "handling handshake"
          await pushable.push(m.codec)
        else:
          for h in m.handlers:
            if (not isNil(h.match) and h.match(msg)) or msg == h.proto:
              trace "found handler for", protocol = msg
              await pushable.push(msg.toBytes())
              try:
                trace "after push", queue = pushable.queue
                await h.protocol.handler(conn, msg)
                trace "after push", queue = pushable.queue

                return
              except CatchableError as exc:
                warn "exception while handling", msg = exc.msg
                return
          warn "no handlers for ", protocol = msg
          await pushable.push(m.na)
  except CatchableError as exc:
    trace "Exception occurred", exc = exc.msg
  finally:
    trace "leaving multistream loop"

proc addHandler*(m: var MultistreamSelect,
                  codec: string,
                  protocol: LPProtocol,
                  matcher: Matcher = nil) =
  ## register a protocol
  trace "registering protocol", codec = codec
  m.handlers.add(HandlerHolder(proto: codec,
                               protocol: protocol,
                               match: matcher))

proc addHandler*(m: var MultistreamSelect,
                    codec: string,
                    handler: LPProtoHandler,
                    matcher: Matcher = nil) =
  ## helper to allow registering pure handlers

  trace "registering proto handler", codec = codec
  let protocol = LPProtocol(codec: codec, handler: handler)
  m.handlers.add(HandlerHolder(proto: codec,
                               protocol: protocol,
                               match: matcher))
