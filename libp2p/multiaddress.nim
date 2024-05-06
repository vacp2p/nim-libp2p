# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module implements MultiAddress.

{.push raises: [].}
{.push public.}

import pkg/chronos, chronicles
import std/[nativesockets, net, hashes]
import tables, strutils, sets
import multicodec, multihash, multibase, transcoder, vbuffer, peerid,
       protobuf/minprotobuf, errors, utility
import stew/[base58, base32, endians2, results]
export results, minprotobuf, vbuffer, utility

logScope:
  topics = "libp2p multiaddress"

type
  MAKind* = enum
    None, Fixed, Length, Path, Marker

  MAProtocol* = object
    mcodec*: MultiCodec
    size*: int
    kind: MAKind
    coder*: Transcoder

  MultiAddress* = object
    data: VBuffer

  MaPatternOp* = enum
    Eq, Or, And

  MaPattern* = object
    operator*: MaPatternOp
    args*: seq[MaPattern]
    value*: MultiCodec

  MaPatResult* = object
    flag*: bool
    rem*: seq[MultiCodec]

  MaResult*[T] = Result[T, string]

  MaError* = object of LPError
  MaInvalidAddress* = object of MaError

  IpTransportProtocol* = enum
    tcpProtocol
    udpProtocol

const
  # These are needed in order to avoid an ambiguity error stemming from
  # some cint constants with the same name defined in the posix modules
  IPPROTO_TCP = Protocol.IPPROTO_TCP
  IPPROTO_UDP = Protocol.IPPROTO_UDP

proc data*(ma: MultiAddress): VBuffer =
  ## Returns the data buffer of the MultiAddress.
  return ma.data

proc hash*(a: MultiAddress): Hash =
  var h: Hash = 0
  h = h !& hash(a.data.buffer)
  h = h !& hash(a.data.offset)
  !$h

proc ip4StB(s: string, vb: var VBuffer): bool =
  ## IPv4 stringToBuffer() implementation.
  try:
    var a = parseIpAddress(s)
    if a.family == IpAddressFamily.IPv4:
      vb.writeArray(a.address_v4)
      result = true
  except CatchableError:
    discard

proc ip4BtS(vb: var VBuffer, s: var string): bool =
  ## IPv4 bufferToString() implementation.
  var a = IpAddress(family: IpAddressFamily.IPv4)
  if vb.readArray(a.address_v4) == 4:
    s = $a
    result = true

proc ip4VB(vb: var VBuffer): bool =
  ## IPv4 validateBuffer() implementation.
  var a = IpAddress(family: IpAddressFamily.IPv4)
  if vb.readArray(a.address_v4) == 4:
    result = true

proc ip6StB(s: string, vb: var VBuffer): bool =
  ## IPv6 stringToBuffer() implementation.
  try:
    var a = parseIpAddress(s)
    if a.family == IpAddressFamily.IPv6:
      vb.writeArray(a.address_v6)
      result = true
  except CatchableError:
    discard

proc ip6BtS(vb: var VBuffer, s: var string): bool =
  ## IPv6 bufferToString() implementation.
  var a = IpAddress(family: IpAddressFamily.IPv6)
  if vb.readArray(a.address_v6) == 16:
    s = $a
    result = true

proc ip6VB(vb: var VBuffer): bool =
  ## IPv6 validateBuffer() implementation.
  var a = IpAddress(family: IpAddressFamily.IPv6)
  if vb.readArray(a.address_v6) == 16:
    result = true

template pathStringToBuffer(s: string, vb: var VBuffer): bool =
  if len(s) > 0:
    vb.writeSeq(s)
    true
  else:
    false

template pathBufferToString(vb: var VBuffer, s: var string): bool =
  s = ""
  if (vb.readSeq(s) > 0) and (len(s) > 0):
    true
  else:
    false

template pathBufferToStringNoSlash(vb: var VBuffer, s: var string): bool =
  s = ""
  if (vb.readSeq(s) > 0) and (len(s) > 0) and (s.find('/') == -1):
    true
  else:
    false

template pathValidateBuffer(vb: var VBuffer): bool =
  var s = ""
  pathBufferToString(vb, s)

template pathValidateBufferNoSlash(vb: var VBuffer): bool =
  var s = ""
  pathBufferToStringNoSlash(vb, s)

proc ip6zoneStB(s: string, vb: var VBuffer): bool =
  ## IPv6 stringToBuffer() implementation.
  pathStringToBuffer(s, vb)

proc ip6zoneBtS(vb: var VBuffer, s: var string): bool =
  ## IPv6 bufferToString() implementation.
  pathBufferToStringNoSlash(vb, s)

proc ip6zoneVB(vb: var VBuffer): bool =
  ## IPv6 validateBuffer() implementation.
  pathValidateBufferNoSlash(vb)

proc portStB(s: string, vb: var VBuffer): bool =
  ## Port number stringToBuffer() implementation.
  var port: array[2, byte]
  try:
    var nport = parseInt(s)
    if (nport >= 0) and (nport < 65536):
      port[0] = cast[byte]((nport shr 8) and 0xFF)
      port[1] = cast[byte](nport and 0xFF)
      vb.writeArray(port)
      result = true
  except CatchableError:
    discard

proc portBtS(vb: var VBuffer, s: var string): bool =
  ## Port number bufferToString() implementation.
  var port: array[2, byte]
  if vb.readArray(port) == 2:
    let nport =
      (safeConvert[uint16](port[0]) shl 8) or safeConvert[uint16](port[1])
    s = $nport
    result = true

proc portVB(vb: var VBuffer): bool =
  ## Port number validateBuffer() implementation.
  var port: array[2, byte]
  if vb.readArray(port) == 2:
    result = true

proc p2pStB(s: string, vb: var VBuffer): bool =
  ## P2P address stringToBuffer() implementation.
  try:
    var data = Base58.decode(s)
    var mh: MultiHash
    if MultiHash.decode(data, mh).isOk:
      vb.writeSeq(data)
      result = true
  except CatchableError:
    discard

proc p2pBtS(vb: var VBuffer, s: var string): bool =
  ## P2P address bufferToString() implementation.
  var address = newSeq[byte]()
  if vb.readSeq(address) > 0:
    var mh: MultiHash
    if MultiHash.decode(address, mh).isOk:
      s = Base58.encode(address)
      result = true

proc p2pVB(vb: var VBuffer): bool =
  ## P2P address validateBuffer() implementation.
  var address = newSeq[byte]()
  if vb.readSeq(address) > 0:
    var mh: MultiHash
    if MultiHash.decode(address, mh).isOk:
      result = true

proc onionStB(s: string, vb: var VBuffer): bool =
  try:
    var parts = s.split(':')
    if len(parts) != 2:
      return false
    if len(parts[0]) != 16:
      return false
    var address = Base32Lower.decode(parts[0].toLowerAscii())
    var nport = parseInt(parts[1])
    if (nport > 0 and nport < 65536) and len(address) == 10:
      address.setLen(12)
      address[10] = cast[byte]((nport shr 8) and 0xFF)
      address[11] = cast[byte](nport and 0xFF)
      vb.writeArray(address)
      result = true
  except CatchableError:
    discard

proc onionBtS(vb: var VBuffer, s: var string): bool =
  ## ONION address bufferToString() implementation.
  var buf: array[12, byte]
  if vb.readArray(buf) == 12:
    let nport =
      (safeConvert[uint16](buf[10]) shl 8) or safeConvert[uint16](buf[11])
    s = Base32Lower.encode(buf.toOpenArray(0, 9))
    s.add(":")
    s.add($nport)
    result = true

proc onionVB(vb: var VBuffer): bool =
  ## ONION address validateBuffer() implementation.
  var buf: array[12, byte]
  if vb.readArray(buf) == 12:
    result = true

proc onion3StB(s: string, vb: var VBuffer): bool =
  try:
    var parts = s.split(':')
    if len(parts) != 2:
      return false
    if len(parts[0]) != 56:
      return false
    var address = Base32Lower.decode(parts[0].toLowerAscii())
    var nport = parseInt(parts[1])
    if (nport > 0 and nport < 65536) and len(address) == 35:
      address.setLen(37)
      address[35] = cast[byte]((nport shr 8) and 0xFF)
      address[36] = cast[byte](nport and 0xFF)
      vb.writeArray(address)
      result = true
  except CatchableError:
    discard

proc onion3BtS(vb: var VBuffer, s: var string): bool =
  ## ONION address bufferToString() implementation.
  var buf: array[37, byte]
  if vb.readArray(buf) == 37:
    var nport =
      (safeConvert[uint16](buf[35]) shl 8) or safeConvert[uint16](buf[36])
    s = Base32Lower.encode(buf.toOpenArray(0, 34))
    s.add(":")
    s.add($nport)
    result = true

proc onion3VB(vb: var VBuffer): bool =
  ## ONION address validateBuffer() implementation.
  var buf: array[37, byte]
  if vb.readArray(buf) == 37:
    result = true

proc unixStB(s: string, vb: var VBuffer): bool =
  ## Unix socket name stringToBuffer() implementation.
  pathStringToBuffer(s, vb)

proc unixBtS(vb: var VBuffer, s: var string): bool =
  ## Unix socket name bufferToString() implementation.
  pathBufferToString(vb, s)

proc unixVB(vb: var VBuffer): bool =
  ## Unix socket name validateBuffer() implementation.
  pathValidateBuffer(vb)

proc dnsStB(s: string, vb: var VBuffer): bool =
  ## DNS name stringToBuffer() implementation.
  pathStringToBuffer(s, vb)

proc dnsBtS(vb: var VBuffer, s: var string): bool =
  ## DNS name bufferToString() implementation.
  pathBufferToStringNoSlash(vb, s)

proc dnsVB(vb: var VBuffer): bool =
  ## DNS name validateBuffer() implementation.
  pathValidateBufferNoSlash(vb)

proc mapEq*(codec: string): MaPattern =
  ## ``Equal`` operator for pattern
  result.operator = Eq
  result.value = multiCodec(codec)

proc mapOr*(args: varargs[MaPattern]): MaPattern =
  ## ``Or`` operator for pattern
  result.operator = Or
  result.args = @args

proc mapAnd*(args: varargs[MaPattern]): MaPattern =
  ## ``And`` operator for pattern
  result.operator = And
  result.args = @args

const
  TranscoderIP4* = Transcoder(
    stringToBuffer: ip4StB,
    bufferToString: ip4BtS,
    validateBuffer: ip4VB
  )
  TranscoderIP6* = Transcoder(
    stringToBuffer: ip6StB,
    bufferToString: ip6BtS,
    validateBuffer: ip6VB
  )
  TranscoderIP6Zone* = Transcoder(
    stringToBuffer: ip6zoneStB,
    bufferToString: ip6zoneBtS,
    validateBuffer: ip6zoneVB
  )
  TranscoderUnix* = Transcoder(
    stringToBuffer: unixStB,
    bufferToString: unixBtS,
    validateBuffer: unixVB
  )
  TranscoderP2P* = Transcoder(
    stringToBuffer: p2pStB,
    bufferToString: p2pBtS,
    validateBuffer: p2pVB
  )
  TranscoderPort* = Transcoder(
    stringToBuffer: portStB,
    bufferToString: portBtS,
    validateBuffer: portVB
  )
  TranscoderOnion* = Transcoder(
    stringToBuffer: onionStB,
    bufferToString: onionBtS,
    validateBuffer: onionVB
  )
  TranscoderOnion3* = Transcoder(
    stringToBuffer: onion3StB,
    bufferToString: onion3BtS,
    validateBuffer: onion3VB
  )
  TranscoderDNS* = Transcoder(
    stringToBuffer: dnsStB,
    bufferToString: dnsBtS,
    validateBuffer: dnsVB
  )
  ProtocolsList = [
    MAProtocol(
      mcodec: multiCodec("ip4"), kind: Fixed, size: 4,
      coder: TranscoderIP4
    ),
    MAProtocol(
      mcodec: multiCodec("tcp"), kind: Fixed, size: 2,
      coder: TranscoderPort
    ),
    MAProtocol(
      mcodec: multiCodec("udp"), kind: Fixed, size: 2,
      coder: TranscoderPort
    ),
    MAProtocol(
      mcodec: multiCodec("ip6"), kind: Fixed, size: 16,
      coder: TranscoderIP6
    ),
    MAProtocol(
      mcodec: multiCodec("dccp"), kind: Fixed, size: 2,
      coder: TranscoderPort
    ),
    MAProtocol(
      mcodec: multiCodec("sctp"), kind: Fixed, size: 2,
      coder: TranscoderPort
    ),
    MAProtocol(
      mcodec: multiCodec("udt"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("utp"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("http"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("https"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("quic"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("quic-v1"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("ip6zone"), kind: Length, size: 0,
      coder: TranscoderIP6Zone
    ),
    MAProtocol(
      mcodec: multiCodec("onion"), kind: Fixed, size: 10,
      coder: TranscoderOnion
    ),
    MAProtocol(
      mcodec: multiCodec("onion3"), kind: Fixed, size: 37,
      coder: TranscoderOnion3
    ),
    MAProtocol(
      mcodec: multiCodec("ws"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("wss"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("tls"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("ipfs"), kind: Length, size: 0,
      coder: TranscoderP2P
    ),
    MAProtocol(
      mcodec: multiCodec("p2p"), kind: Length, size: 0,
      coder: TranscoderP2P
    ),
    MAProtocol(
      mcodec: multiCodec("unix"), kind: Path, size: 0,
      coder: TranscoderUnix
    ),
    MAProtocol(
      mcodec: multiCodec("dns"), kind: Length, size: 0,
      coder: TranscoderDNS
    ),
    MAProtocol(
      mcodec: multiCodec("dns4"), kind: Length, size: 0,
      coder: TranscoderDNS
    ),
    MAProtocol(
      mcodec: multiCodec("dns6"), kind: Length, size: 0,
      coder: TranscoderDNS
    ),
    MAProtocol(
      mcodec: multiCodec("dnsaddr"), kind: Length, size: 0,
      coder: TranscoderDNS
    ),
    MAProtocol(
      mcodec: multiCodec("p2p-circuit"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("p2p-websocket-star"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("p2p-webrtc-star"), kind: Marker, size: 0
    ),
    MAProtocol(
      mcodec: multiCodec("p2p-webrtc-direct"), kind: Marker, size: 0
    )
  ]

  DNSANY* = mapEq("dns")
  DNS4* = mapEq("dns4")
  DNS6* = mapEq("dns6")
  DNSADDR* = mapEq("dnsaddr")
  IP4* = mapEq("ip4")
  IP6* = mapEq("ip6")
  DNS* = mapOr(DNSANY, DNS4, DNS6, DNSADDR)
  IP* = mapOr(IP4, IP6)
  DNS_OR_IP* = mapOr(DNS, IP)
  TCP_DNS* = mapAnd(DNS, mapEq("tcp"))
  TCP_IP* = mapAnd(IP, mapEq("tcp"))
  TCP* = mapOr(TCP_DNS, TCP_IP)
  UDP_DNS* = mapAnd(DNS, mapEq("udp"))
  UDP_IP* = mapAnd(IP, mapEq("udp"))
  UDP* = mapOr(UDP_DNS, UDP_IP)
  UTP* = mapAnd(UDP, mapEq("utp"))
  QUIC* = mapAnd(UDP, mapEq("quic"))
  UNIX* = mapEq("unix")
  WS_DNS* = mapAnd(TCP_DNS, mapEq("ws"))
  WS_IP* = mapAnd(TCP_IP, mapEq("ws"))
  WS* = mapAnd(TCP, mapEq("ws"))
  TLS_WS* = mapOr(mapEq("wss"), mapAnd(mapEq("tls"), mapEq("ws")))
  WSS_DNS* = mapAnd(TCP_DNS, TLS_WS)
  WSS_IP* = mapAnd(TCP_IP, TLS_WS)
  WSS* = mapAnd(TCP, TLS_WS)
  WebSockets_DNS* = mapOr(WS_DNS, WSS_DNS)
  WebSockets_IP* = mapOr(WS_IP, WSS_IP)
  WebSockets* = mapOr(WS, WSS)
  Onion3* = mapEq("onion3")
  TcpOnion3* = mapAnd(TCP, Onion3)

  Unreliable* = mapOr(UDP)

  Reliable* = mapOr(TCP, UTP, QUIC, WebSockets)

  P2PPattern* = mapEq("p2p")

  IPFS* = mapAnd(Reliable, P2PPattern)

  HTTP* = mapOr(
    mapAnd(TCP, mapEq("http")),
    mapAnd(IP, mapEq("http")),
    mapAnd(DNS, mapEq("http"))
  )

  HTTPS* = mapOr(
    mapAnd(TCP, mapEq("https")),
    mapAnd(IP, mapEq("https")),
    mapAnd(DNS, mapEq("https"))
  )

  WebRTCDirect* = mapOr(
    mapAnd(HTTP, mapEq("p2p-webrtc-direct")),
    mapAnd(HTTPS, mapEq("p2p-webrtc-direct"))
  )

  CircuitRelay* = mapEq("p2p-circuit")

proc initMultiAddressCodeTable(): Table[MultiCodec,
                                        MAProtocol] {.compileTime.} =
  for item in ProtocolsList:
    result[item.mcodec] = item

const
  CodeAddresses = initMultiAddressCodeTable()

proc trimRight(s: string, ch: char): string =
  ## Consume trailing characters ``ch`` from string ``s`` and return result.
  var m = 0
  for i in countdown(s.high, 0):
    if s[i] == ch:
      inc(m)
    else:
      break
  result = s[0..(s.high - m)]

proc protoCode*(ma: MultiAddress): MaResult[MultiCodec] =
  ## Returns MultiAddress ``ma`` protocol code.
  var header: uint64
  var vb = ma
  if vb.data.readVarint(header) == -1:
    err("multiaddress: Malformed binary address!")
  else:
    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      err("multiaddress: Unsupported protocol '" & $header & "'")
    else:
      ok(proto.mcodec)

proc protoName*(ma: MultiAddress): MaResult[string] =
  ## Returns MultiAddress ``ma`` protocol name.
  var header: uint64
  var vb = ma
  if vb.data.readVarint(header) == -1:
    err("multiaddress: Malformed binary address!")
  else:
    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      err("multiaddress: Unsupported protocol '" & $header & "'")
    else:
      ok($(proto.mcodec))

proc protoArgument*(ma: MultiAddress,
                    value: var openArray[byte]): MaResult[int] =
  ## Returns MultiAddress ``ma`` protocol argument value.
  ##
  ## If current MultiAddress do not have argument value, then result will be
  ## ``0``.
  var header: uint64
  var vb = ma
  var buffer: seq[byte]
  if vb.data.readVarint(header) == -1:
    err("multiaddress: Malformed binary address!")
  else:
    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      err("multiaddress: Unsupported protocol '" & $header & "'")
    else:
      var res: int
      if proto.kind == Fixed:
        res = proto.size
        if len(value) >= res and
          vb.data.readArray(value.toOpenArray(0, proto.size - 1)) != proto.size:
          err("multiaddress: Decoding protocol error")
        else:
          ok(res)
      elif proto.kind in {MAKind.Length, Path}:
        if vb.data.readSeq(buffer) == -1:
          err("multiaddress: Decoding protocol error")
        else:
          res = len(buffer)
          if len(value) >= res:
            copyMem(addr value[0], addr buffer[0], res)
          ok(res)
      else:
        ok(res)

proc protoAddress*(ma: MultiAddress): MaResult[seq[byte]] =
  ## Returns MultiAddress ``ma`` protocol address binary blob.
  ##
  ## If current MultiAddress do not have argument value, then result array will
  ## be empty.
  var buffer = newSeq[byte](len(ma.data.buffer))
  let res = ? protoArgument(ma, buffer)
  buffer.setLen(res)
  ok(buffer)

proc protoArgument*(ma: MultiAddress): MaResult[seq[byte]] =
  ## Returns MultiAddress ``ma`` protocol address binary blob.
  ##
  ## If current MultiAddress do not have argument value, then result array will
  ## be empty.
  ma.protoAddress()

proc getPart(ma: MultiAddress, index: int): MaResult[MultiAddress] =
  var header: uint64
  var data = newSeq[byte]()
  var offset = 0
  var vb = ma
  var res: MultiAddress
  res.data = initVBuffer()

  if index < 0: return err("multiaddress: negative index gived to getPart")

  while offset <= index:
    if vb.data.readVarint(header) == -1:
      return err("multiaddress: Malformed binary address!")

    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      return err("multiaddress: Unsupported protocol '" & $header & "'")

    elif proto.kind == Fixed:
      data.setLen(proto.size)
      if vb.data.readArray(data) != proto.size:
        return err("multiaddress: Decoding protocol error")

      if offset == index:
        res.data.writeVarint(header)
        res.data.writeArray(data)
        res.data.finish()
    elif proto.kind in {MAKind.Length, Path}:
      if vb.data.readSeq(data) == -1:
        return err("multiaddress: Decoding protocol error")

      if offset == index:
        res.data.writeVarint(header)
        res.data.writeSeq(data)
        res.data.finish()
    elif proto.kind == Marker:
      if offset == index:
        res.data.writeVarint(header)
        res.data.finish()
    inc(offset)
  ok(res)

proc getParts[U, V](ma: MultiAddress,
                    slice: HSlice[U, V]): MaResult[MultiAddress] =
  when slice.a is BackwardsIndex or slice.b is BackwardsIndex:
    let maLength = ? len(ma)
  template normalizeIndex(index): int =
    when index is BackwardsIndex: maLength - int(index)
    else: int(index)
  let
    indexStart = normalizeIndex(slice.a)
    indexEnd = normalizeIndex(slice.b)
  var res: MultiAddress
  for i in indexStart..indexEnd:
    ? res.append(? ma[i])
  ok(res)

proc `[]`*(ma: MultiAddress,
           i: int | BackwardsIndex): MaResult[MultiAddress] {.inline.} =
  ## Returns part with index ``i`` of MultiAddress ``ma``.
  when i is BackwardsIndex:
    let maLength = ? len(ma)
    ma.getPart(maLength - int(i))
  else:
    ma.getPart(i)

proc `[]`*(ma: MultiAddress, slice: HSlice): MaResult[MultiAddress] {.inline.} =
  ## Returns parts with slice ``slice`` of MultiAddress ``ma``.
  ma.getParts(slice)

iterator items*(ma: MultiAddress): MaResult[MultiAddress] =
  ## Iterates over all addresses inside of MultiAddress ``ma``.
  var header: uint64
  var data = newSeq[byte]()
  var vb = ma
  while true:
    if vb.data.isEmpty():
      break

    var res = MultiAddress(data: initVBuffer())
    if vb.data.readVarint(header) == -1:
      yield err(MaResult[MultiAddress], "Malformed binary address!")

    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      yield err(MaResult[MultiAddress], "Unsupported protocol '" &
                $header & "'")

    elif proto.kind == Fixed:
      data.setLen(proto.size)
      if vb.data.readArray(data) != proto.size:
        yield err(MaResult[MultiAddress], "Decoding protocol error")

      res.data.writeVarint(header)
      res.data.writeArray(data)
    elif proto.kind in {MAKind.Length, Path}:
      if vb.data.readSeq(data) == -1:
        yield err(MaResult[MultiAddress], "Decoding protocol error")

      res.data.writeVarint(header)
      res.data.writeSeq(data)
    elif proto.kind == Marker:
      res.data.writeVarint(header)
    res.data.finish()
    yield ok(MaResult[MultiAddress], res)

proc len*(ma: MultiAddress): MaResult[int] =
  var counter: int
  for part in ma:
    if part.isErr: return err(part.error)
    counter.inc()
  ok(counter)

proc contains*(ma: MultiAddress, codec: MultiCodec): MaResult[bool] {.inline.} =
  ## Returns ``true``, if address with MultiCodec ``codec`` present in
  ## MultiAddress ``ma``.
  for item in ma.items:
    let code = ?(?item).protoCode()
    if code == codec:
      return ok(true)
  ok(false)

proc `[]`*(ma: MultiAddress,
           codec: MultiCodec): MaResult[MultiAddress] {.inline.} =
  ## Returns partial MultiAddress with MultiCodec ``codec`` and present in
  ## MultiAddress ``ma``.
  for item in ma.items:
    if ?(?item).protoCode == codec:
      return item
  err("multiaddress: Codec is not present in address")

proc toString*(value: MultiAddress): MaResult[string] =
  ## Return string representation of MultiAddress ``value``.
  var header: uint64
  var vb = value
  var parts = newSeq[string]()
  var part: string
  var res: string
  while true:
    if vb.data.isEmpty():
      break
    if vb.data.readVarint(header) == -1:
      return err("multiaddress: Malformed binary address!")
    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      return err("multiaddress: Unsupported protocol '" & $header & "'")
    if proto.kind in {Fixed, Length, Path}:
      if isNil(proto.coder.bufferToString):
        return err("multiaddress: Missing protocol '" & $(proto.mcodec) &
                   "' coder")
      if not proto.coder.bufferToString(vb.data, part):
        return err("multiaddress: Decoding protocol error")
      parts.add($(proto.mcodec))
      if len(part) > 0 and (proto.kind == Path) and (part[0] == '/'):
        parts.add(part[1..^1])
      else:
        parts.add(part)
    elif proto.kind == Marker:
      parts.add($(proto.mcodec))
  if len(parts) > 0:
    res = "/" & parts.join("/")
  ok(res)

proc `$`*(value: MultiAddress): string =
  ## Return string representation of MultiAddress ``value``.
  let s = value.toString()
  if s.isErr: s.error
  else: s[]

proc protocols*(value: MultiAddress): MaResult[seq[MultiCodec]] =
  ## Returns list of protocol codecs inside of MultiAddress ``value``.
  var res = newSeq[MultiCodec]()
  for item in value.items():
    res.add(?(?item).protoCode())
  ok(res)

proc hex*(value: MultiAddress): string =
  ## Return hexadecimal string representation of MultiAddress ``value``.
  $(value.data)

proc write*(vb: var VBuffer, ma: MultiAddress) {.inline.} =
  ## Write MultiAddress value ``ma`` to buffer ``vb``.
  vb.writeArray(ma.data.buffer)

proc encode*(mbtype: typedesc[MultiBase], encoding: string,
             ma: MultiAddress): string {.inline.} =
  ## Get MultiBase encoded representation of ``ma`` using encoding
  ## ``encoding``.
  result = MultiBase.encode(encoding, ma.data.buffer)

proc validate*(ma: MultiAddress): bool =
  ## Returns ``true`` if MultiAddress ``ma`` is valid.
  var header: uint64
  var vb = ma
  while true:
    if vb.data.isEmpty():
      break
    if vb.data.readVarint(header) == -1:
      return false
    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      return false
    if proto.kind in {Fixed, Length, Path}:
      if isNil(proto.coder.validateBuffer):
        return false
      if not proto.coder.validateBuffer(vb.data):
        return false
    else:
      discard
  result = true

proc init*(
    mtype: typedesc[MultiAddress], protocol: MultiCodec,
    value: openArray[byte] = []): MaResult[MultiAddress] =
  ## Initialize MultiAddress object from protocol id ``protocol`` and array
  ## of bytes ``value``.
  let proto = CodeAddresses.getOrDefault(protocol)
  if proto.kind == None:
    err("multiaddress: Protocol not found")
  else:
    var res: MultiAddress
    res.data = initVBuffer()
    res.data.writeVarint(cast[uint64](proto.mcodec))
    case proto.kind
    of Fixed, Length, Path:
      if len(value) == 0:
        err("multiaddress: Value must not be empty array")
      else:
        if proto.kind == Fixed:
          res.data.writeArray(value)
        else:
          res.data.writeSeq(value)
        res.data.finish()
        ok(res)
    of Marker:
      if len(value) != 0:
        err("multiaddress: Value must be empty for markers")
      else:
        res.data.finish()
        ok(res)
    of None:
      raiseAssert "None checked above"

proc init*(mtype: typedesc[MultiAddress], protocol: MultiCodec,
           value: PeerId): MaResult[MultiAddress] {.inline.} =
  ## Initialize MultiAddress object from protocol id ``protocol`` and peer id
  ## ``value``.
  init(mtype, protocol, value.data)

proc init*(mtype: typedesc[MultiAddress], protocol: MultiCodec,
           value: int): MaResult[MultiAddress] =
  ## Initialize MultiAddress object from protocol id ``protocol`` and integer
  ## ``value``. This procedure can be used to instantiate ``tcp``, ``udp``,
  ## ``dccp`` and ``sctp`` MultiAddresses.
  var allowed = [multiCodec("tcp"), multiCodec("udp"), multiCodec("dccp"),
                 multiCodec("sctp")]
  if protocol notin allowed:
    err("multiaddress: Incorrect protocol for integer value")
  else:
    let proto = CodeAddresses.getOrDefault(protocol)
    var res: MultiAddress
    res.data = initVBuffer()
    res.data.writeVarint(cast[uint64](proto.mcodec))
    if value < 0 or value > 65535:
      err("multiaddress: Incorrect integer value")
    else:
      res.data.writeArray(toBytesBE(cast[uint16](value)))
      res.data.finish()
      ok(res)

proc getProtocol(name: string): MAProtocol {.inline.} =
  let mc = MultiCodec.codec(name)
  if mc != InvalidMultiCodec:
    result = CodeAddresses.getOrDefault(mc)

proc init*(mtype: typedesc[MultiAddress],
           value: string): MaResult[MultiAddress] =
  ## Initialize MultiAddress object from string representation ``value``.
  if len(value) == 0 or value == "/":
    return err("multiaddress: Address must not be empty!")
  var parts = value.trimRight('/').split('/')
  if len(parts[0]) != 0:
    err("multiaddress: Invalid MultiAddress, must start with `/`")
  else:
    var offset = 1
    var res: MultiAddress
    res.data = initVBuffer()
    while offset < len(parts):
      let part = parts[offset]
      let proto = getProtocol(part)
      if proto.kind == None:
        return err("multiaddress: Unsupported protocol '" & part & "'")
      else:
        if proto.kind in {Fixed, Length, Path}:
          if isNil(proto.coder.stringToBuffer):
            return err("multiaddress: Missing protocol '" &
                        part & "' transcoder")

          if offset + 1 >= len(parts):
            return err("multiaddress: Missing protocol '" & part & "' argument")

        if proto.kind in {Fixed, Length}:
          res.data.write(proto.mcodec)
          let res = proto.coder.stringToBuffer(parts[offset + 1], res.data)
          if not res:
            return err("multiaddress: Error encoding `" & part & "/" &
                       parts[offset + 1] & "`")
          offset += 2

        elif proto.kind == Path:
          var path = "/" & (parts[(offset + 1)..^1].join("/"))
          res.data.write(proto.mcodec)
          if not proto.coder.stringToBuffer(path, res.data):
            return err("multiaddress: Error encoding `" & part & "/" &
                       path & "`")

          break
        elif proto.kind == Marker:
          res.data.write(proto.mcodec)
          offset += 1
    res.data.finish()
    ok(res)

proc init*(mtype: typedesc[MultiAddress],
           data: openArray[byte]): MaResult[MultiAddress] =
  ## Initialize MultiAddress with array of bytes ``data``.
  if len(data) == 0:
    err("multiaddress: Address must not be empty!")
  else:
    var res: MultiAddress
    res.data = initVBuffer()
    res.data.buffer.setLen(len(data))
    copyMem(addr res.data.buffer[0], unsafeAddr data[0], len(data))
    if not res.validate():
      err("multiaddress: Incorrect MultiAddress!")
    else:
      ok(res)

proc init*(mtype: typedesc[MultiAddress]): MultiAddress =
  ## Initialize empty MultiAddress.
  result.data = initVBuffer()

proc init*(mtype: typedesc[MultiAddress], address: IpAddress,
           protocol: IpTransportProtocol, port: Port): MultiAddress =
  var res: MultiAddress
  res.data = initVBuffer()
  let
    networkProto = case address.family
      of IpAddressFamily.IPv4: getProtocol("ip4")
      of IpAddressFamily.IPv6: getProtocol("ip6")

    transportProto = case protocol
      of tcpProtocol: getProtocol("tcp")
      of udpProtocol: getProtocol("udp")

  res.data.write(networkProto.mcodec)
  case address.family
    of IpAddressFamily.IPv4: res.data.writeArray(address.address_v4)
    of IpAddressFamily.IPv6: res.data.writeArray(address.address_v6)
  res.data.write(transportProto.mcodec)
  res.data.writeArray(toBytesBE(uint16(port)))
  res.data.finish()
  res

proc init*(mtype: typedesc[MultiAddress], address: TransportAddress,
           protocol = IPPROTO_TCP): MaResult[MultiAddress] =
  ## Initialize MultiAddress using chronos.TransportAddress (IPv4/IPv6/Unix)
  ## and protocol information (UDP/TCP).
  var res: MultiAddress
  res.data = initVBuffer()
  let protoProto = case protocol
                   of IPPROTO_TCP: getProtocol("tcp")
                   of IPPROTO_UDP: getProtocol("udp")
                   else: default(MAProtocol)
  if protoProto.size == 0:
    return err("multiaddress: protocol should be either TCP or UDP")
  if address.family == AddressFamily.IPv4:
    res.data.write(getProtocol("ip4").mcodec)
    res.data.writeArray(address.address_v4)
    res.data.write(protoProto.mcodec)
    discard protoProto.coder.stringToBuffer($address.port, res.data)
  elif address.family == AddressFamily.IPv6:
    res.data.write(getProtocol("ip6").mcodec)
    res.data.writeArray(address.address_v6)
    res.data.write(protoProto.mcodec)
    discard protoProto.coder.stringToBuffer($address.port, res.data)
  elif address.family == AddressFamily.Unix:
    res.data.write(getProtocol("unix").mcodec)
    res.data.writeSeq(address.address_un)
  res.data.finish()
  ok(res)

proc isEmpty*(ma: MultiAddress): bool =
  ## Returns ``true``, if MultiAddress ``ma`` is empty or non initialized.
  result = len(ma.data) == 0

proc concat*(m1, m2: MultiAddress): MaResult[MultiAddress] =
  var res: MultiAddress
  res.data = initVBuffer()
  res.data.buffer = m1.data.buffer & m2.data.buffer
  if not res.validate():
    err("multiaddress: Incorrect MultiAddress!")
  else:
    ok(res)

proc append*(m1: var MultiAddress, m2: MultiAddress): MaResult[void] =
  m1.data.buffer &= m2.data.buffer
  if not m1.validate():
    err("multiaddress: Incorrect MultiAddress!")
  else:
    ok()

proc `&`*(m1, m2: MultiAddress): MultiAddress {.
     raises: [LPError].} =
  ## Concatenates two addresses ``m1`` and ``m2``, and returns result.
  ##
  ## This procedure performs validation of concatenated result and can raise
  ## exception on error.
  ##

  concat(m1, m2).tryGet()

proc `&=`*(m1: var MultiAddress, m2: MultiAddress) {.
     raises: [LPError].} =
  ## Concatenates two addresses ``m1`` and ``m2``.
  ##
  ## This procedure performs validation of concatenated result and can raise
  ## exception on error.
  ##

  m1.append(m2).tryGet()

proc `==`*(m1: var MultiAddress, m2: MultiAddress): bool =
  ## Check of two MultiAddress are equal
  m1.data == m2.data

proc matchPart(pat: MaPattern, protos: seq[MultiCodec]): MaPatResult =
  var empty: seq[MultiCodec]
  var pcs = protos
  if pat.operator == Or:
    result = MaPatResult(flag: false, rem: empty)
    for a in pat.args:
      let res = a.matchPart(pcs)
      if res.flag:
        #Greedy Or
        if result.flag == false or
             result.rem.len > res.rem.len:
          result = res
  elif pat.operator == And:
    if len(pcs) < len(pat.args):
      return MaPatResult(flag: false, rem: empty)
    for i in 0..<len(pat.args):
      let res = pat.args[i].matchPart(pcs)
      if not res.flag:
        return MaPatResult(flag: false, rem: res.rem)
      pcs = res.rem
    result = MaPatResult(flag: true, rem: pcs)
  elif pat.operator == Eq:
    if len(pcs) == 0:
      return MaPatResult(flag: false, rem: empty)
    if pcs[0] == pat.value:
      return MaPatResult(flag: true, rem: pcs[1..^1])
    result = MaPatResult(flag: false, rem: empty)

proc match*(pat: MaPattern, address: MultiAddress): bool =
  ## Match full ``address`` using pattern ``pat`` and return ``true`` if
  ## ``address`` satisfies pattern.
  let protos = address.protocols().valueOr: return false
  let res = matchPart(pat, protos)
  res.flag and (len(res.rem) == 0)

proc matchPartial*(pat: MaPattern, address: MultiAddress): bool =
  ## Match prefix part of ``address`` using pattern ``pat`` and return
  ## ``true`` if ``address`` starts with pattern.
  let protos = address.protocols().valueOr: return false
  let res = matchPart(pat, protos)
  res.flag

proc `$`*(pat: MaPattern): string =
  ## Return pattern ``pat`` as string.
  var sub = newSeq[string]()
  for a in pat.args:
    sub.add($a)
  if pat.operator == And:
    result = sub.join("/")
  elif pat.operator == Or:
    result = "(" & sub.join("|") & ")"
  elif pat.operator == Eq:
    result = $pat.value

proc bytes*(value: MultiAddress): seq[byte] =
  value.data.buffer

proc write*(pb: var ProtoBuffer, field: int, value: MultiAddress) {.inline.} =
  write(pb, field, value.data.buffer)

proc getField*(pb: ProtoBuffer, field: int,
               value: var MultiAddress): ProtoResult[bool] {.
     inline.} =
  var buffer: seq[byte]
  let res = ? pb.getField(field, buffer)
  if not(res):
    ok(false)
  else:
    value = MultiAddress.init(buffer).valueOr:
      return err(ProtoError.IncorrectBlob)
    ok(true)

proc getRepeatedField*(pb: ProtoBuffer, field: int,
                       value: var seq[MultiAddress]): ProtoResult[bool] {.
     inline.} =
  ## Read repeated field from protobuf message. ``field`` is field number.
  ## If the message is malformed, an error is returned. If field is not present
  ## in message, then ``ok(false)`` is returned and value is empty. If field is
  ## present, but no items could be parsed, then
  ## ``err(ProtoError.IncorrectBlob)`` is returned and value is empty.
  ## If field is present and some item could be parsed, then ``true`` is
  ## returned and value contains the parsed values.
  var items: seq[seq[byte]]
  value.setLen(0)
  let res = ? pb.getRepeatedField(field, items)
  if not(res):
    ok(false)
  else:
    for item in items:
      let ma = MultiAddress.init(item).valueOr:
        debug "Unsupported MultiAddress in blob", ma = item
        continue

      value.add(ma)
    if value.len == 0:
      err(ProtoError.IncorrectBlob)
    else:
      ok(true)
