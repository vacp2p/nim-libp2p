# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[strutils, sequtils, tables]
import chronos, chronicles, stew/byteutils
import stream/connection,
       protocols/protocol

logScope:
  topics = "libp2p multistream"

const
  MsgSize = 1024
  Codec = "/multistream/1.0.0"

  Na = "na\n"
  Ls = "ls\n"

type
  Matcher* = proc (proto: string): bool {.gcsafe, raises: [].}

  MultiStreamError* = object of LPError

  HandlerHolder* = ref object
    protos*: seq[string]
    protocol*: LPProtocol
    match*: Matcher
    openedStreams: CountTable[PeerId]

  MultistreamSelect* = ref object of RootObj
    handlers*: seq[HandlerHolder]
    codec*: string

proc new*(T: typedesc[MultistreamSelect]): T =
  T(
    codec: Codec,
  )

template validateSuffix(str: string): untyped =
  if str.endsWith("\n"):
    str.removeSuffix("\n")
  else:
    raise (ref MultiStreamError)(msg:
      "MultistreamSelect failed, malformed message")

proc select*(
    _: MultistreamSelect | type MultistreamSelect,
    conn: Connection,
    proto: seq[string]
): Future[string] {.async: (raises: [
    CancelledError, LPStreamError, MultiStreamError]).} =
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
    raise (ref MultiStreamError)(msg: "MultistreamSelect handshake failed")
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

proc select*(
    _: MultistreamSelect | type MultistreamSelect,
    conn: Connection,
    proto: string
): Future[bool] {.async: (raises: [
    CancelledError, LPStreamError, MultiStreamError]).} =
  if proto.len > 0:
    (await MultistreamSelect.select(conn, @[proto])) == proto
  else:
    (await MultistreamSelect.select(conn, @[])) == Codec

proc select*(
    m: MultistreamSelect,
    conn: Connection
): Future[bool] {.async: (raises: [
    CancelledError, LPStreamError, MultiStreamError], raw: true).} =
  m.select(conn, "")

proc list*(
    m: MultistreamSelect,
    conn: Connection
): Future[seq[string]] {.async: (raises: [
    CancelledError, LPStreamError, MultiStreamError]).} =
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
    matchers = newSeq[Matcher](),
    active: bool = false
): Future[string] {.async: (raises: [
    CancelledError, LPStreamError, MultiStreamError]).} =
  trace "Starting multistream negotiation", conn, handshaked = active
  var handshaked = active
  while not conn.atEof:
    var ms = string.fromBytes(await conn.readLp(MsgSize))
    validateSuffix(ms)

    if not handshaked and ms != Codec:
      debug "expected handshake message", conn, instead=ms
      raise (ref MultiStreamError)(msg:
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
    elif ms in protos or matchers.anyIt(it(ms)):
      trace "found handler", conn, protocol = ms
      await conn.writeLp(ms & "\n")
      conn.protocol = ms
      return ms
    else:
      trace "no handlers", conn, protocol = ms
      await conn.writeLp(Na)

proc handle*(
    m: MultistreamSelect,
    conn: Connection,
    active: bool = false) {.async: (raises: [CancelledError]).} =
  trace "Starting multistream handler", conn, handshaked = active
  var
    protos: seq[string]
    matchers: seq[Matcher]
  for h in m.handlers:
    if h.match != nil:
      matchers.add(h.match)
    for proto in h.protos:
      protos.add(proto)

  try:
    let ms = await MultistreamSelect.handle(conn, protos, matchers, active)
    for h in m.handlers:
      if (h.match != nil and h.match(ms)) or h.protos.contains(ms):
        trace "found handler", conn, protocol = ms

        var protocolHolder = h
        let maxIncomingStreams = protocolHolder.protocol.maxIncomingStreams
        if protocolHolder.openedStreams.getOrDefault(conn.peerId) >=
            maxIncomingStreams:
          debug "Max streams for protocol reached, blocking new stream",
            conn, protocol = ms, maxIncomingStreams
          return
        protocolHolder.openedStreams.inc(conn.peerId)
        try:
          await protocolHolder.protocol.handler(conn, ms)
        finally:
          protocolHolder.openedStreams.inc(conn.peerId, -1)
          if protocolHolder.openedStreams[conn.peerId] == 0:
            protocolHolder.openedStreams.del(conn.peerId)
        return
    debug "no handlers", conn, ms
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

proc start*(m: MultistreamSelect) {.async: (raises: []).} =
  await noCancel allFutures(m.handlers.mapIt(it.protocol.start()))

proc stop*(m: MultistreamSelect) {.async: (raises: []).} =
  await noCancel allFutures(m.handlers.mapIt(it.protocol.stop()))
