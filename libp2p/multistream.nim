# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[strutils, sequtils]
import chronos, chronicles, stew/byteutils
import stream/connection,
       protocols/protocol

logScope:
  topics = "libp2p multistream"

const
  MsgSize = 64*1024
  Codec = "/multistream/1.0.0"

  Na = "na\n"
  Ls = "ls\n"

type
  Matcher* = proc (proto: string): bool {.gcsafe, raises: [Defect].}

  MultiStreamError* = object of LPError

  HandlerHolder* = object
    protos*: seq[string]
    protocol*: LPProtocol
    match*: Matcher

  MultistreamSelect* = ref object of RootObj
    handlers*: seq[HandlerHolder]
    codec*: string

proc new*(T: typedesc[MultistreamSelect]): T =
  T(codec: Codec)

template validateSuffix(str: string): untyped =
    if str.endsWith("\n"):
      str.removeSuffix("\n")
    else:
      raise newException(MultiStreamError, "MultistreamSelect failed, malformed message")

proc select*(_: MultistreamSelect | type MultistreamSelect,
             conn: Connection,
             proto: seq[string]):
             Future[string] {.async.} =
  trace "initiating handshake", conn, codec = Codec
  ## select a remote protocol
  await conn.writeLp(Codec & "\n") # write handshake
  if proto.len() > 0:
    trace "selecting proto", conn, proto = proto[0]
    await conn.writeLp((proto[0] & "\n")) # select proto

  var s = string.fromBytes((await conn.readLp(MsgSize))) # read ms header
  validateSuffix(s)

  if s != Codec:
    notice "handshake failed", conn, codec = s
    raise newException(MultiStreamError, "MultistreamSelect handshake failed")
  else:
    trace "multistream handshake success", conn

  if proto.len() == 0: # no protocols, must be a handshake call
    return Codec
  else:
    s = string.fromBytes(await conn.readLp(MsgSize)) # read the first proto
    validateSuffix(s)
    trace "reading first requested proto", conn
    if s == proto[0]:
      trace "successfully selected ", conn, proto = proto[0]
      conn.protocol = proto[0]
      return proto[0]
    elif proto.len > 1:
      # Try to negotiate alternatives
      let protos = proto[1..<proto.len()]
      trace "selecting one of several protos", conn, protos = protos
      for p in protos:
        trace "selecting proto", conn, proto = p
        await conn.writeLp((p & "\n")) # select proto
        s = string.fromBytes(await conn.readLp(MsgSize)) # read the first proto
        validateSuffix(s)
        if s == p:
          trace "selected protocol", conn, protocol = s
          conn.protocol = s
          return s
      return ""
    else:
      # No alternatives, fail
      return ""

proc select*(_: MultistreamSelect | type MultistreamSelect,
             conn: Connection,
             proto: string): Future[bool] {.async.} =
  if proto.len > 0:
    return (await MultistreamSelect.select(conn, @[proto])) == proto
  else:
    return (await MultistreamSelect.select(conn, @[])) == Codec

proc select*(m: MultistreamSelect, conn: Connection): Future[bool] =
  m.select(conn, "")

proc list*(m: MultistreamSelect,
           conn: Connection): Future[seq[string]] {.async.} =
  ## list remote protos requests on connection
  if not await m.select(conn):
    return

  await conn.writeLp(Ls) # send ls

  var list = newSeq[string]()
  let ms = string.fromBytes(await conn.readLp(MsgSize))
  for s in ms.split("\n"):
    if s.len() > 0:
      list.add(s)

  result = list

proc handle*(
  _: type MultistreamSelect,
  conn: Connection,
  protos: seq[string],
  active: bool = false,
  ): Future[string] {.async, gcsafe.} =
  trace "Starting multistream negotiation", conn, handshaked = active
  var handshaked = active
  while not conn.atEof:
    var ms = string.fromBytes(await conn.readLp(MsgSize))
    validateSuffix(ms)

    if not handshaked and ms != Codec:
      debug "expected handshake message", conn, instead=ms
      raise newException(CatchableError,
                         "MultistreamSelect handling failed, invalid first message")

    trace "handle: got request", conn, ms
    if ms.len() <= 0:
      trace "handle: invalid proto", conn
      await conn.writeLp(Na)

    case ms:
    of "ls":
      trace "handle: listing protos", conn
      #TODO this doens't seem to follow spec, each protocol
      # should be length prefixed. Not very important
      # since LS is getting deprecated
      await conn.writeLp(protos.join("\n") & "\n")
    of Codec:
      if not handshaked:
        await conn.writeLp(Codec & "\n")
        handshaked = true
      else:
        trace "handle: sending `na` for duplicate handshake while handshaked",
          conn
        await conn.writeLp(Na)
    else:
      if ms in protos:
        trace "found handler", conn, protocol = ms
        await conn.writeLp(ms & "\n")
        conn.protocol = ms
        return ms
      trace "no handlers", conn, protocol = ms
      await conn.writeLp(Na)

proc handle*(m: MultistreamSelect, conn: Connection, active: bool = false) {.async, gcsafe.} =
  trace "Starting multistream handler", conn, handshaked = active
  var handshaked = active
  var protos: seq[string]
  for h in m.handlers:
    for proto in h.protos:
      protos.add(proto)

  try:
    let negotiated = await MultistreamSelect.handle(conn, protos, active)
    for h in m.handlers:
      if h.protos.contains(negotiated):
        await h.protocol.handler(conn, negotiated)
        return
    debug "no handlers", conn, negotiated
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Exception in multistream", conn, msg = exc.msg
  finally:
    await conn.close()

  trace "Stopped multistream handler", conn

proc addHandler*(m: MultistreamSelect,
                 codecs: seq[string],
                 protocol: LPProtocol,
                 matcher: Matcher = nil) =
  trace "registering protocols", protos = codecs
  m.handlers.add(HandlerHolder(protos: codecs,
                               protocol: protocol,
                               match: matcher))

proc addHandler*(m: MultistreamSelect,
                 codec: string,
                 protocol: LPProtocol,
                 matcher: Matcher = nil) =
  addHandler(m, @[codec], protocol, matcher)

proc addHandler*(m: MultistreamSelect,
                 codec: string,
                 handler: LPProtoHandler,
                 matcher: Matcher = nil) =
  ## helper to allow registering pure handlers
  trace "registering proto handler", proto = codec
  let protocol = new LPProtocol
  protocol.codec = codec
  protocol.handler = handler

  m.handlers.add(HandlerHolder(protos: @[codec],
                               protocol: protocol,
                               match: matcher))

proc start*(m: MultistreamSelect) {.async.} =
  await allFutures(m.handlers.mapIt(it.protocol.start()))

proc stop*(m: MultistreamSelect) {.async.} =
  await allFutures(m.handlers.mapIt(it.protocol.stop()))
