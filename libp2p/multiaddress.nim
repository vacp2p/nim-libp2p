## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements MultiAddress.
import tables, strutils, net
import multicodec, multihash, multibase, transcoder, base58, base32, vbuffer
from peer import PeerID

{.deadCodeElim:on.}

type
  MAKind* = enum
    None, Fixed, Length, Path, Marker

  MAProtocol* = object
    mcodec*: MultiCodec
    size*: int
    kind: MAKind
    coder*: Transcoder

  MultiAddress* = object
    data*: VBuffer

  MaPatternOp* = enum
    Eq, Or, And

  MaPattern* = object
    operator*: MaPatternOp
    args*: seq[MaPattern]
    value*: MultiCodec

  MaPatResult* = object
    flag*: bool
    rem*: seq[MultiCodec]

  MultiAddressError* = object of Exception

proc ip4StB(s: string, vb: var VBuffer): bool =
  ## IPv4 stringToBuffer() implementation.
  try:
    var a = parseIpAddress(s)
    if a.family == IpAddressFamily.IPv4:
      vb.writeArray(a.address_v4)
      result = true
  except:
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
  except:
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

proc ip6zoneStB(s: string, vb: var VBuffer): bool =
  ## IPv6 stringToBuffer() implementation.
  if len(s) > 0:
    vb.writeSeq(s)
    result = true

proc ip6zoneBtS(vb: var VBuffer, s: var string): bool =
  ## IPv6 bufferToString() implementation.
  if vb.readSeq(s) > 0:
    result = true

proc ip6zoneVB(vb: var VBuffer): bool =
  ## IPv6 validateBuffer() implementation.
  var s = ""
  if vb.readSeq(s) > 0:
    if s.find('/') == -1:
      result = true

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
  except:
    discard

proc portBtS(vb: var VBuffer, s: var string): bool =
  ## Port number bufferToString() implementation.
  var port: array[2, byte]
  if vb.readArray(port) == 2:
    var nport = (cast[uint16](port[0]) shl 8) or cast[uint16](port[1])
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
    if MultiHash.decode(data, mh) >= 0:
      vb.writeSeq(data)
      result = true
  except:
    discard

proc p2pBtS(vb: var VBuffer, s: var string): bool =
  ## P2P address bufferToString() implementation.
  var address = newSeq[byte]()
  if vb.readSeq(address) > 0:
    var mh: MultiHash
    if MultiHash.decode(address, mh) >= 0:
      s = Base58.encode(address)
      result = true

proc p2pVB(vb: var VBuffer): bool =
  ## P2P address validateBuffer() implementation.
  var address = newSeq[byte]()
  if vb.readSeq(address) > 0:
    var mh: MultiHash
    if MultiHash.decode(address, mh) >= 0:
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
  except:
    discard

proc onionBtS(vb: var VBuffer, s: var string): bool =
  ## ONION address bufferToString() implementation.
  var buf: array[12, byte]
  if vb.readArray(buf) == 12:
    var nport = (cast[uint16](buf[10]) shl 8) or cast[uint16](buf[11])
    s = Base32Lower.encode(buf.toOpenArray(0, 9))
    s.add(":")
    s.add($nport)
    result = true

proc onionVB(vb: var VBuffer): bool =
  ## ONION address validateBuffer() implementation.
  var buf: array[12, byte]
  if vb.readArray(buf) == 12:
    result = true

proc unixStB(s: string, vb: var VBuffer): bool =
  ## Unix socket name stringToBuffer() implementation.
  if len(s) > 0:
    vb.writeSeq(s)
    result = true

proc unixBtS(vb: var VBuffer, s: var string): bool =
  ## Unix socket name bufferToString() implementation.
  s = ""
  if vb.readSeq(s) > 0:
    result = true

proc unixVB(vb: var VBuffer): bool =
  ## Unix socket name validateBuffer() implementation.
  var s = ""
  if vb.readSeq(s) > 0:
    result = true

proc dnsStB(s: string, vb: var VBuffer): bool =
  ## DNS name stringToBuffer() implementation.
  if len(s) > 0:
    vb.writeSeq(s)
    result = true

proc dnsBtS(vb: var VBuffer, s: var string): bool =
  ## DNS name bufferToString() implementation.
  s = ""
  if vb.readSeq(s) > 0:
    result = true

proc dnsVB(vb: var VBuffer): bool =
  ## DNS name validateBuffer() implementation.
  var s = ""
  if vb.readSeq(s) > 0:
    if s.find('/') == -1:
      result = true

proc pEq(codec: string): MaPattern =
  ## ``Equal`` operator for pattern
  result.operator = Eq
  result.value = multiCodec(codec)

proc pOr(args: varargs[MaPattern]): MaPattern =
  ## ``Or`` operator for pattern
  result.operator = Or
  result.args = @args

proc pAnd(args: varargs[MaPattern]): MaPattern =
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
      mcodec: multiCodec("ip6zone"), kind: Length, size: 0,
      coder: TranscoderIP6Zone
    ),
    MAProtocol(
      mcodec: multiCodec("onion"), kind: Fixed, size: 10,
      coder: TranscoderOnion
    ),
    MAProtocol(
      mcodec: multiCodec("ws"), kind: Marker, size: 0
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

  DNS4* = pEq("dns4")
  DNS6* = pEq("dns6")
  IP4* = pEq("ip4")
  IP6* = pEq("ip6")
  DNS* = pOr(pEq("dnsaddr"), DNS4, DNS6)
  IP* = pOr(IP4, IP6)
  TCP* = pOr(pAnd(DNS, pEq("tcp")), pAnd(IP, pEq("tcp")))
  UDP* = pOr(pAnd(DNS, pEq("udp")), pAnd(IP, pEq("udp")))
  UTP* = pAnd(UDP, pEq("utp"))
  QUIC* = pAnd(UDP, pEq("quic"))

  Unreliable* = pOr(UDP)

  Reliable* = pOr(TCP, UTP, QUIC)

  IPFS* = pAnd(Reliable, pEq("p2p"))

  HTTP* = pOr(
    pAnd(TCP, pEq("http")),
    pAnd(IP, pEq("http")),
    pAnd(DNS, pEq("http"))
  )

  HTTPS* = pOr(
    pAnd(TCP, pEq("https")),
    pAnd(IP, pEq("https")),
    pAnd(DNS, pEq("https"))
  )

  WebRTCDirect* = pOr(
    pAnd(HTTP, pEq("p2p-webrtc-direct")),
    pAnd(HTTPS, pEq("p2p-webrtc-direct"))
  )

proc initMultiAddressCodeTable(): Table[MultiCodec,
                                        MAProtocol] {.compileTime.} =
  result = initTable[MultiCodec, MAProtocol]()
  for item in ProtocolsList:
    result[item.mcodec] = item

const
  CodeAddresses = initMultiAddressCodeTable()

proc trimRight(s: string, ch: char): string =
  ## Consume trailing characters ``ch`` from string ``s`` and return result.
  var m = 0
  for i in countdown(len(s) - 1, 0):
    if s[i] == ch:
      inc(m)
    else:
      break
  result = s[0..(len(s) - 1 - m)]

proc shcopy*(m1: var MultiAddress, m2: MultiAddress) =
  shallowCopy(m1.data.buffer, m2.data.buffer)
  m1.data.offset = m2.data.offset
  m1.data.length = m2.data.length

proc protoCode*(ma: MultiAddress): MultiCodec =
  ## Returns MultiAddress ``ma`` protocol code.
  var header: uint64
  var vb: MultiAddress
  shcopy(vb, ma)
  if vb.data.readVarint(header) == -1:
    raise newException(MultiAddressError, "Malformed binary address!")
  let proto = CodeAddresses.getOrDefault(MultiCodec(header))
  if proto.kind == None:
    raise newException(MultiAddressError,
                       "Unsupported protocol '" & $header & "'")
  result = proto.mcodec

proc protoName*(ma: MultiAddress): string =
  ## Returns MultiAddress ``ma`` protocol name.
  var header: uint64
  var vb: MultiAddress
  shcopy(vb, ma)
  if vb.data.readVarint(header) == -1:
    raise newException(MultiAddressError, "Malformed binary address!")
  let proto = CodeAddresses.getOrDefault(MultiCodec(header))
  if proto.kind == None:
    raise newException(MultiAddressError,
                       "Unsupported protocol '" & $header & "'")
  result = $(proto.mcodec)

proc protoArgument*(ma: MultiAddress, value: var openarray[byte]): int =
  ## Returns MultiAddress ``ma`` protocol argument value.
  ##
  ## If current MultiAddress do not have argument value, then result will be
  ## ``0``.
  var header: uint64
  var vb: MultiAddress
  var buffer: seq[byte]
  shcopy(vb, ma)
  if vb.data.readVarint(header) == -1:
    raise newException(MultiAddressError, "Malformed binary address!")
  let proto = CodeAddresses.getOrDefault(MultiCodec(header))
  if proto.kind == None:
    raise newException(MultiAddressError,
                       "Unsupported protocol '" & $header & "'")
  if proto.kind == Fixed:
    result = proto.size
    if len(value) >= result:
      if vb.data.readArray(value) != proto.size:
        raise newException(MultiAddressError, "Decoding protocol error")
  elif proto.kind in {Length, Path}:
    if vb.data.readSeq(buffer) == -1:
      raise newException(MultiAddressError, "Decoding protocol error")
    result = len(buffer)
    if len(value) >= result:
      copyMem(addr value[0], addr buffer[0], result)

proc getPart(ma: MultiAddress, index: int): MultiAddress =
  var header: uint64
  var data = newSeq[byte]()
  var offset = 0
  var vb = ma
  result.data = initVBuffer()
  while offset <= index:
    if vb.data.readVarint(header) == -1:
      raise newException(MultiAddressError, "Malformed binary address!")
    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      raise newException(MultiAddressError,
                         "Unsupported protocol '" & $header & "'")
    elif proto.kind == Fixed:
      data.setLen(proto.size)
      if vb.data.readArray(data) != proto.size:
        raise newException(MultiAddressError, "Decoding protocol error")
      if offset == index:
        result.data.writeVarint(header)
        result.data.writeArray(data)
        result.data.finish()
    elif proto.kind in {Length, Path}:
      if vb.data.readSeq(data) == -1:
        raise newException(MultiAddressError, "Decoding protocol error")
      if offset == index:
        result.data.writeVarint(header)
        result.data.writeSeq(data)
        result.data.finish()
    elif proto.kind == Marker:
      if offset == index:
        result.data.writeVarint(header)
        result.data.finish()
    inc(offset)

proc `[]`*(ma: MultiAddress, i: int): MultiAddress {.inline.} =
  ## Returns part with index ``i`` of MultiAddress ``ma``.
  result = ma.getPart(i)

iterator items*(ma: MultiAddress): MultiAddress =
  ## Iterates over all addresses inside of MultiAddress ``ma``.
  var header: uint64
  var data = newSeq[byte]()
  var vb = ma
  while true:
    if vb.data.isEmpty():
      break
    var res = MultiAddress(data: initVBuffer())
    if vb.data.readVarint(header) == -1:
      raise newException(MultiAddressError, "Malformed binary address!")
    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      raise newException(MultiAddressError,
                         "Unsupported protocol '" & $header & "'")
    elif proto.kind == Fixed:
      data.setLen(proto.size)
      if vb.data.readArray(data) != proto.size:
        raise newException(MultiAddressError, "Decoding protocol error")
      res.data.writeVarint(header)
      res.data.writeArray(data)
    elif proto.kind in {Length, Path}:
      if vb.data.readSeq(data) == -1:
        raise newException(MultiAddressError, "Decoding protocol error")
      res.data.writeVarint(header)
      res.data.writeSeq(data)
    elif proto.kind == Marker:
      res.data.writeVarint(header)
    res.data.finish()
    yield res

proc `$`*(value: MultiAddress): string =
  ## Return string representation of MultiAddress ``value``.
  var header: uint64
  var vb = value
  var data = newSeq[byte]()
  var parts = newSeq[string]()
  var part: string
  while true:
    if vb.data.isEmpty():
      break
    if vb.data.readVarint(header) == -1:
      raise newException(MultiAddressError, "Malformed binary address!")
    let proto = CodeAddresses.getOrDefault(MultiCodec(header))
    if proto.kind == None:
      raise newException(MultiAddressError,
                         "Unsupported protocol '" & $header & "'")
    if proto.kind in {Fixed, Length, Path}:
      if isNil(proto.coder.bufferToString):
        raise newException(MultiAddressError,
                           "Missing protocol '" & $(proto.mcodec) & "' coder")
      if not proto.coder.bufferToString(vb.data, part):
        raise newException(MultiAddressError, "Decoding protocol error")
      parts.add($(proto.mcodec))
      if proto.kind == Path and part[0] == '/':
        parts.add(part[1..^1])
      else:
        parts.add(part)
    elif proto.kind == Marker:
      parts.add($(proto.mcodec))
  if len(parts) > 0:
    result = "/" & parts.join("/")

proc protocols*(value: MultiAddress): seq[MultiCodec] =
  ## Returns list of protocol codecs inside of MultiAddress ``value``.
  result = newSeq[MultiCodec]()
  for item in value.items():
    result.add(item.protoCode())

proc hex*(value: MultiAddress): string =
  ## Return hexadecimal string representation of MultiAddress ``value``.
  result = $(value.data)

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
  var vb: MultiAddress
  shcopy(vb, ma)
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

proc init*(mtype: typedesc[MultiAddress], protocol: MultiCodec,
           value: openarray[byte]): MultiAddress =
  ## Initialize MultiAddress object from protocol id ``protocol`` and array
  ## of bytes ``value``.
  let proto = CodeAddresses.getOrDefault(protocol)
  if proto.kind == None:
    raise newException(MultiAddressError, "Protocol not found")
  result.data = initVBuffer()
  result.data.writeVarint(cast[uint64](proto.mcodec))
  if proto.kind in {Fixed, Length, Path}:
    if len(value) == 0:
      raise newException(MultiAddressError, "Value must not be empty array")
    if proto.kind == Fixed:
      result.data.writeArray(value)
    else:
      var data = newSeq[byte](len(value))
      copyMem(addr data[0], unsafeAddr value[0], len(value))
      result.data.writeSeq(data)
    result.data.finish()

proc init*(mtype: typedesc[MultiAddress], protocol: MultiCodec,
           value: PeerID): MultiAddress {.inline.} =
  ## Initialize MultiAddress object from protocol id ``protocol`` and peer id
  ## ``value``.
  init(mtype, protocol, cast[seq[byte]](value))

proc init*(mtype: typedesc[MultiAddress], protocol: MultiCodec): MultiAddress =
  ## Initialize MultiAddress object from protocol id ``protocol``.
  let proto = CodeAddresses.getOrDefault(protocol)
  if proto.kind == None:
    raise newException(MultiAddressError, "Protocol not found")
  result.data = initVBuffer()
  if proto.kind != Marker:
    raise newException(MultiAddressError, "Protocol missing value")
  result.data.writeVarint(cast[uint64](proto.mcodec))
  result.data.finish()

proc getProtocol(name: string): MAProtocol {.inline.} =
  let mc = MultiCodec.codec(name)
  if mc != InvalidMultiCodec:
    result = CodeAddresses.getOrDefault(mc)

proc init*(mtype: typedesc[MultiAddress], value: string): MultiAddress =
  ## Initialize MultiAddress object from string representation ``value``.
  var parts = value.trimRight('/').split('/')
  if len(parts[0]) != 0:
    raise newException(MultiAddressError,
                       "Invalid MultiAddress, must start with `/`")
  var offset = 1
  result.data = initVBuffer()
  while offset < len(parts):
    let part = parts[offset]
    let proto = getProtocol(part)
    if proto.kind == None:
      raise newException(MultiAddressError,
                         "Unsupported protocol '" & part & "'")
    if proto.kind in {Fixed, Length, Path}:
      if isNil(proto.coder.stringToBuffer):
        raise newException(MultiAddressError,
                           "Missing protocol '" & part & "' transcoder")
      if offset + 1 >= len(parts):
        raise newException(MultiAddressError,
                           "Missing protocol '" & part & "' argument")

    if proto.kind in {Fixed, Length}:
      result.data.write(proto.mcodec)
      let res = proto.coder.stringToBuffer(parts[offset + 1], result.data)
      if not res:
        raise newException(MultiAddressError,
                           "Error encoding `$1/$2`" % [part, parts[offset + 1]])
      offset += 2
    elif proto.kind == Path:
      var path = "/" & (parts[(offset + 1)..^1].join("/"))
      result.data.write(proto.mcodec)
      if not proto.coder.stringToBuffer(path, result.data):
        raise newException(MultiAddressError,
                           "Error encoding `$1/$2`" % [part, path])
      break
    elif proto.kind == Marker:
      result.data.write(proto.mcodec)
      offset += 1
  result.data.finish()

proc init*(mtype: typedesc[MultiAddress], data: openarray[byte]): MultiAddress =
  ## Initialize MultiAddress with array of bytes ``data``.
  if len(data) == 0:
    raise newException(MultiAddressError, "Address could not be empty!")
  result.data = initVBuffer()
  result.data.buffer.setLen(len(data))
  copyMem(addr result.data.buffer[0], unsafeAddr data[0], len(data))
  if not result.validate():
    raise newException(MultiAddressError, "Incorrect MultiAddress!")

proc init*(mtype: typedesc[MultiAddress]): MultiAddress =
  ## Initialize empty MultiAddress.
  result.data = initVBuffer()

proc isEmpty*(ma: MultiAddress): bool =
  ## Returns ``true``, if MultiAddress ``ma`` is empty or non initialized.
  result = len(ma.data) == 0

proc `&`*(m1, m2: MultiAddress): MultiAddress =
  ## Concatenates two addresses ``m1`` and ``m2``, and returns result.
  ##
  ## This procedure performs validation of concatenated result and can raise
  ## exception on error.
  result.data = initVBuffer()
  result.data.buffer = m1.data.buffer & m2.data.buffer
  if not result.validate():
    raise newException(MultiAddressError, "Incorrect MultiAddress!")

proc `&=`*(m1: var MultiAddress, m2: MultiAddress) =
  ## Concatenates two addresses ``m1`` and ``m2``.
  ##
  ## This procedure performs validation of concatenated result and can raise
  ## exception on error.
  m1.data.buffer &= m2.data.buffer
  if not m1.validate():
    raise newException(MultiAddressError, "Incorrect MultiAddress!")

proc isWire*(ma: MultiAddress): bool =
  ## Returns ``true`` if MultiAddress ``ma`` is one of:
  ## - {IP4}/{TCP, UDP}
  ## - {IP6}/{TCP, UDP}
  ## - {UNIX}/{PATH}
  var state = 0
  try:
    for part in ma.items():
      if state == 0:
        let code = part.protoCode()
        if code == multiCodec("ip4") or code == multiCodec("ip6"):
          inc(state)
          continue
        elif code == multiCodec("unix"):
          result = true
          break
        else:
          result = false
          break
      elif state == 1:
        if part.protoCode == multiCodec("tcp") or
           part.protoCode == multiCodec("udp"):
          inc(state)
          result = true
        else:
          result = false
          break
      else:
        result = false
        break
  except:
    result = false

proc matchPart(pat: MaPattern, protos: seq[MultiCodec]): MaPatResult =
  var empty: seq[MultiCodec]
  var pcs = protos
  if pat.operator == Or:
    for a in pat.args:
      let res = a.matchPart(pcs)
      if res.flag:
        return MaPatResult(flag: true, rem: res.rem)
    result = MaPatResult(flag: false, rem: empty)
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
  var protos = address.protocols()
  let res = matchPart(pat, protos)
  result = res.flag and (len(res.rem) == 0)

proc matchPartial*(pat: MaPattern, address: MultiAddress): bool =
  ## Match prefix part of ``address`` using pattern ``pat`` and return
  ## ``true`` if ``address`` starts with pattern.
  var protos = address.protocols()
  let res = matchPart(pat, protos)
  result = res.flag

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
