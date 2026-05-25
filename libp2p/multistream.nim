# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[strutils, sequtils]
import chronos, results, chronicles, stew/byteutils
import stream/connection, protocols/protocol

logScope:
  topics = "libp2p multistream"

const
  MsgSize = 1024
  Codec = "/multistream/1.0.0"

  Na = "na\n"
  Ls = "ls\n"

type
  Matcher* = proc(proto: string): bool {.gcsafe, raises: [].}

  MultiStreamError* = object of LPError

  HandlerHolder* = ref object
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
    raise (ref MultiStreamError)(msg: "MultistreamSelect failed, malformed message")

proc select*(
    _: MultistreamSelect | type MultistreamSelect, stream: Stream, proto: seq[string]
): Future[string] {.async: (raises: [CancelledError, LPStreamError, MultiStreamError]).} =
  trace "initiating handshake", stream, codec = Codec
  ## select a remote protocol
  await stream.writeLp(Codec & "\n") # write handshake
  if proto.len() > 0:
    trace "selecting proto", stream, proto = proto[0]
    await stream.writeLp((proto[0] & "\n")) # select proto

  var s = string.fromBytes((await stream.readLp(MsgSize))) # read ms header
  validateSuffix(s)

  if s != Codec:
    notice "handshake failed", stream, codec = s
    raise (ref MultiStreamError)(msg: "MultistreamSelect handshake failed")
  else:
    trace "multistream handshake success", stream

  if proto.len() == 0: # no protocols, must be a handshake call
    return Codec
  else:
    s = string.fromBytes(await stream.readLp(MsgSize)) # read the first proto
    validateSuffix(s)
    trace "reading first requested proto", stream, s, proto
    if s == proto[0]:
      trace "successfully selected ", stream, proto = proto[0]
      stream.protocol = proto[0]
      return proto[0]
    elif proto.len > 1:
      # Try to negotiate alternatives
      let protos = proto[1 ..< proto.len()]
      trace "selecting one of several protos", stream, protos = protos
      for p in protos:
        trace "selecting proto", stream, proto = p
        await stream.writeLp((p & "\n")) # select proto
        s = string.fromBytes(await stream.readLp(MsgSize)) # read the first proto
        validateSuffix(s)
        if s == p:
          trace "selected protocol", stream, protocol = s
          stream.protocol = s
          return s
      return ""
    else:
      # No alternatives, fail
      return ""

proc select*(
    _: MultistreamSelect | type MultistreamSelect, stream: Stream, proto: string
): Future[bool] {.async: (raises: [CancelledError, LPStreamError, MultiStreamError]).} =
  if proto.len > 0:
    (await MultistreamSelect.select(stream, @[proto])) == proto
  else:
    (await MultistreamSelect.select(stream, @[])) == Codec

proc select*(
    m: MultistreamSelect, stream: Stream
): Future[bool] {.
    async: (raises: [CancelledError, LPStreamError, MultiStreamError], raw: true)
.} =
  m.select(stream, "")

proc list*(
    m: MultistreamSelect, stream: Stream
): Future[seq[string]] {.
    async: (raises: [CancelledError, LPStreamError, MultiStreamError])
.} =
  ## list remote protos requests on connection
  if not await m.select(stream):
    return

  await stream.writeLp(Ls) # send ls

  var list = newSeq[string]()
  let ms = string.fromBytes(await stream.readLp(MsgSize))
  for s in ms.split("\n"):
    if s.len() > 0:
      list.add(s)

  list

proc handle*(
    _: type MultistreamSelect,
    stream: Stream,
    protos: seq[string],
    matchers = newSeq[Matcher](),
    active: bool = false,
): Future[string] {.async: (raises: [CancelledError, LPStreamError, MultiStreamError]).} =
  trace "Starting multistream negotiation", stream, handshaked = active
  var handshaked = active
  while not stream.atEof:
    var ms = string.fromBytes(await stream.readLp(MsgSize))
    validateSuffix(ms)

    if not handshaked and ms != Codec:
      debug "expected handshake message", stream, instead = ms
      raise (ref MultiStreamError)(
        msg: "MultistreamSelect handling failed, invalid first message"
      )

    trace "handle: got request", stream, ms
    if ms.len() <= 0:
      trace "handle: invalid proto", stream
      await stream.writeLp(Na)

    case ms
    of "ls":
      trace "handle: listing protos", stream
      #TODO this doens't seem to follow spec, each protocol
      # should be length prefixed. Not very important
      # since LS is getting deprecated
      await stream.writeLp(protos.join("\n") & "\n")
    of Codec:
      if not handshaked:
        await stream.writeLp(Codec & "\n")
        handshaked = true
      else:
        trace "handle: sending `na` for duplicate handshake while handshaked", stream
        await stream.writeLp(Na)
    elif ms in protos or matchers.anyIt(it(ms)):
      trace "found handler", stream, protocol = ms
      await stream.writeLp(ms & "\n")
      stream.protocol = ms
      return ms
    else:
      trace "no handlers", stream, protocol = ms
      await stream.writeLp(Na)

proc lookupProtocol*(m: MultistreamSelect, proto: string): Opt[LPProtocol] =
  ## Find the LPProtocol registered for the given protocol string, if any.
  ## Returns `Opt.none` when no handler matches.
  for h in m.handlers:
    if (h.match != nil and h.match(proto)) or h.protos.contains(proto):
      return Opt.some(h.protocol)
  return Opt.none(LPProtocol)

proc handle*(
    m: MultistreamSelect, stream: Stream, active: bool = false
) {.async: (raises: [CancelledError]).} =
  trace "Starting multistream handler", stream, handshaked = active
  var
    protos: seq[string]
    matchers: seq[Matcher]
  for h in m.handlers:
    if h.match != nil:
      matchers.add(h.match)
    for proto in h.protos:
      protos.add(proto)

  try:
    let ms = await MultistreamSelect.handle(stream, protos, matchers, active)
    for h in m.handlers:
      if (h.match != nil and h.match(ms)) or h.protos.contains(ms):
        trace "found handler", stream, protocol = ms

        let protocol = h.protocol

        if not protocol.reserveIncoming(stream.peerId):
          debug "Inbound stream budget exceeded, rejecting incoming stream",
            stream, protocol = ms, peerId = stream.peerId
          return

        try:
          await protocol.handler(stream, ms)
        finally:
          protocol.releaseIncoming(stream.peerId)
        return
    debug "no handlers", stream, ms
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Exception in multistream", stream, description = exc.msg
  finally:
    await stream.close()

  trace "Stopped multistream handler", stream

proc addHandler*(
    m: MultistreamSelect,
    codecs: seq[string],
    protocol: LPProtocol,
    matcher: Matcher = nil,
) =
  trace "registering protocols", protos = codecs
  m.handlers.add(HandlerHolder(protos: codecs, protocol: protocol, match: matcher))

proc addHandler*(
    m: MultistreamSelect, codec: string, protocol: LPProtocol, matcher: Matcher = nil
) =
  addHandler(m, @[codec], protocol, matcher)

proc addHandler*[E](
    m: MultistreamSelect,
    codec: string,
    handler:
      LPProtoHandler | proc(
        stream: Stream, proto: string
      ): InternalRaisesFuture[void, E],
    matcher: Matcher = nil,
) =
  ## helper to allow registering pure handlers
  trace "registering proto handler", proto = codec
  let protocol = new LPProtocol
  protocol.codec = codec
  protocol.handler = handler

  m.handlers.add(HandlerHolder(protos: @[codec], protocol: protocol, match: matcher))

proc start*(m: MultistreamSelect) {.async: (raises: [CancelledError]).} =
  let futs = m.handlers.mapIt(it.protocol.start())
  try:
    await allFutures(futs)
    for fut in futs:
      await fut
  except CancelledError as exc:
    var pending: seq[Future[void].Raising([])]
    doAssert m.handlers.len == futs.len, "Handlers modified while starting"
    for i, fut in futs:
      if not fut.finished:
        pending.add fut.cancelAndWait()
      elif fut.completed:
        pending.add m.handlers[i].protocol.stop()
      else:
        static:
          doAssert typeof(fut).E is (CancelledError,)
    await noCancel allFutures(pending)
    raise exc

proc stop*(m: MultistreamSelect) {.async: (raises: []).} =
  let futs = m.handlers.mapIt(it.protocol.stop())
  await noCancel allFutures(futs)
  for fut in futs:
    await fut
