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
import transcoder, base58, vbuffer

{.deadCodeElim:on.}

const
  P_IP4*         = 0x0004
  P_TCP*         = 0x0006
  P_UDP*         = 0x0111
  P_DCCP*        = 0x0021
  P_IP6*         = 0x0029
  P_IP6ZONE*     = 0x002A
  P_DNS4*        = 0x0036
  P_DNS6*        = 0x0037
  P_DNSADDR*     = 0x0038
  P_QUIC*        = 0x01CC
  P_SCTP*        = 0x0084
  P_UDT*         = 0x012D
  P_UTP*         = 0x012E
  P_UNIX*        = 0x0190
  P_P2P*         = 0x01A5
  P_IPFS*        = 0x01A5 # alias for backwards compatability
  P_HTTP*        = 0x01E0
  P_HTTPS*       = 0x01BB
  P_ONION*       = 0x01BC
  P_WS*          = 0x01DD
  LP2P_WSSTAR*   = 0x01DF
  LP2P_WRTCSTAR* = 0x0113
  LP2P_WRTCDIR*  = 0x0114
  P_P2PCIRCUIT*  = 0x0122

type
  MAKind* = enum
    None, Fixed, Length, Path, Marker

  MAProtocol* = object
    name*: string
    code*: int
    size*: int
    kind: MAKind
    coder*: Transcoder

  MultiAddress* = object
    data*: VBuffer

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
    if nport < 65536:
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
    vb.writeSeq(data)
    result = true
  except:
    discard

proc p2pBtS(vb: var VBuffer, s: var string): bool =
  ## P2P address bufferToString() implementation.
  var address = newSeq[byte]()
  if vb.readSeq(address) > 0:
    s = Base58.encode(address)
    result = true

proc p2pVB(vb: var VBuffer): bool =
  ## P2P address validateBuffer() implementation.
  ## TODO (multihash required)
  var address = newSeq[byte]()
  if vb.readSeq(address) > 0:
    result = true

proc onionStB(s: string, vb: var VBuffer): bool =
  # TODO (base32, multihash required)
  discard

proc onionBtS(vb: var VBuffer, s: var string): bool =
  # TODO (base32, multihash required)
  discard

proc onionVB(vb: var VBuffer): bool =
  # TODO (base32, multihash required)
  discard

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
      name: "ip4", code: P_IP4, kind: Fixed, size: 4,
      coder: TranscoderIP4
    ),
    MAProtocol(
      name: "tcp", code: P_TCP, kind: Fixed, size: 2,
      coder: TranscoderPort
    ),
    MAProtocol(
      name: "udp", code: P_UDP, kind: Fixed, size: 2,
      coder: TranscoderPort
    ),
    MAProtocol(
      name: "ip6", code: P_IP6, kind: Fixed, size: 16,
      coder: TranscoderIP6
    ),
    MAProtocol(
      name: "dccp", code: P_DCCP, kind: Fixed, size: 2,
      coder: TranscoderPort
    ),
    MAProtocol(
      name: "sctp", code: P_SCTP, kind: Fixed, size: 2,
      coder: TranscoderPort
    ),
    MAProtocol(
      name: "udt", code: P_UDT, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "utp", code: P_UTP, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "http", code: P_HTTP, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "https", code: P_HTTPS, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "quic", code: P_QUIC, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "ip6zone", code: P_IP6ZONE, kind: Length, size: 0,
      coder: TranscoderIP6Zone
    ),
    MAProtocol(
      name: "onion", code: P_ONION, kind: Fixed, size: 10,
      coder: TranscoderOnion
    ),
    MAProtocol(
      name: "ws", code: P_WS, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "ws", code: P_WS, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "ipfs", code: P_IPFS, kind: Length, size: 0,
      coder: TranscoderP2P
    ),
    MAProtocol(
      name: "p2p", code: P_P2P, kind: Length, size: 0,
      coder: TranscoderP2P
    ),
    MAProtocol(
      name: "unix", code: P_UNIX, kind: Path, size: 0,
      coder: TranscoderUnix
    ),
    MAProtocol(
      name: "dns4", code: P_DNS4, kind: Length, size: 0,
      coder: TranscoderDNS
    ),
    MAProtocol(
      name: "dns6", code: P_DNS6, kind: Length, size: 0,
      coder: TranscoderDNS
    ),
    MAProtocol(
      name: "dnsaddr", code: P_DNS6, kind: Length, size: 0,
      coder: TranscoderDNS
    ),
    MAProtocol(
      name: "p2p-circuit", code: P_P2PCIRCUIT, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "p2p-websocket-star", code: LP2P_WSSTAR, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "p2p-webrtc-star", code: LP2P_WRTCSTAR, kind: Marker, size: 0
    ),
    MAProtocol(
      name: "p2p-webrtc-direct", code: LP2P_WRTCDIR, kind: Marker, size: 0
    )
  ]

proc initMultiAddressNameTable(): Table[string, MAProtocol] {.compileTime.} =
  result = initTable[string, MAProtocol]()
  for item in ProtocolsList:
    result[item.name] = item

proc initMultiAddressCodeTable(): Table[int, MAProtocol] {.compileTime.} =
  result = initTable[int, MAProtocol]()
  for item in ProtocolsList:
    result[item.code] = item

const
  CodeAddresses = initMultiAddressCodeTable()
  NameAddresses = initMultiAddressNameTable()

proc trimRight(s: string, ch: char): string =
  ## Consume trailing characters ``ch`` from string ``s`` and return result.
  var m = 0
  for i in countdown(len(s) - 1, 0):
    if s[i] == ch:
      inc(m)
    else:
      break
  result = s[0..(len(s) - 1 - m)]

proc protoCode*(mtype: typedesc[MultiAddress], protocol: string): int =
  ## Returns protocol code from protocol name ``protocol``.
  let proto = NameAddresses.getOrDefault(protocol)
  if proto.kind == None:
    raise newException(MultiAddressError, "Protocol not found")
  result = proto.code

proc protoName*(mtype: typedesc[MultiAddress], protocol: int): string =
  ## Returns protocol name from protocol code ``protocol``.
  let proto = CodeAddresses.getOrDefault(protocol)
  if proto.kind == None:
    raise newException(MultiAddressError, "Protocol not found")
  result = proto.name

proc protoCode*(ma: MultiAddress): int =
  ## Returns MultiAddress ``ma`` protocol code.
  discard

proc protoName*(ma: MultiAddress): string =
  ## Returns MultiAddress ``ma`` protocol name.
  discard

proc protoValue*(ma: MultiAddress, value: var openarray[byte]): int =
  ## Returns MultiAddress ``ma`` protocol address value.
  discard

proc getPart(ma: MultiAddress, index: int): MultiAddress =
  var header: uint64
  var data = newSeq[byte]()
  var offset = 0
  var vb = ma
  result.data = initVBuffer()
  while offset <= index:
    if vb.data.readVarint(header) == -1:
      raise newException(MultiAddressError, "Malformed binary address!")
    let proto = CodeAddresses.getOrDefault(int(header))
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
    let proto = CodeAddresses.getOrDefault(int(header))
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
    let proto = CodeAddresses.getOrDefault(int(header))
    if proto.kind == None:
      raise newException(MultiAddressError,
                         "Unsupported protocol '" & $header & "'")
    if proto.kind in {Fixed, Length, Path}:
      if isNil(proto.coder.bufferToString):
        raise newException(MultiAddressError,
                           "Missing protocol '" & proto.name & "' transcoder")
      if not proto.coder.bufferToString(vb.data, part):
        raise newException(MultiAddressError, "Decoding protocol error")
      parts.add(proto.name)
      parts.add(part)
    elif proto.kind == Marker:
      parts.add(proto.name)
  if len(parts) > 0:
    result = "/" & parts.join("/")

proc hex*(value: MultiAddress): string =
  ## Return hexadecimal string representation of MultiAddress ``value``.
  result = $(value.data)

proc buffer*(value: MultiAddress): seq[byte] =
  ## Returns shallow copy of internal buffer
  shallowCopy(result, value.data.buffer)

proc validate*(ma: MultiAddress): bool =
  ## Returns ``true`` if MultiAddress ``ma`` is valid.
  var header: uint64
  var vb = ma
  while true:
    if vb.data.isEmpty():
      break
    if vb.data.readVarint(header) == -1:
      return false
    let proto = CodeAddresses.getOrDefault(int(header))
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

proc init*(mtype: typedesc[MultiAddress], protocol: int,
           value: openarray[byte]): MultiAddress =
  ## Initialize MultiAddress object from protocol id ``protocol`` and array
  ## of bytes ``value``.
  let proto = CodeAddresses.getOrDefault(protocol)
  if proto.kind == None:
    raise newException(MultiAddressError, "Protocol not found")
  result.data = initVBuffer()
  result.data.writeVarint(cast[uint64](proto.code))
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

proc init*(mtype: typedesc[MultiAddress], protocol: int): MultiAddress =
  ## Initialize MultiAddress object from protocol id ``protocol``.
  let proto = CodeAddresses.getOrDefault(protocol)
  if proto.kind == None:
    raise newException(MultiAddressError, "Protocol not found")
  result.data = initVBuffer()
  if proto.kind != Marker:
    raise newException(MultiAddressError, "Protocol missing value")
  result.data.writeVarint(cast[uint64](proto.code))
  result.data.finish()

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
    let proto = NameAddresses.getOrDefault(part)
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
      result.data.writeVarint(cast[uint](proto.code))
      if not proto.coder.stringToBuffer(parts[offset + 1], result.data):
        raise newException(MultiAddressError,
                           "Error encoding `$1/$2`" % [part, parts[offset + 1]])
      offset += 2
    elif proto.kind == Path:
      var path = "/" & (parts[(offset + 1)..^1].join("/"))
      result.data.writeVarint(cast[uint](proto.code))
      if not proto.coder.stringToBuffer(path, result.data):
        raise newException(MultiAddressError,
                           "Error encoding `$1/$2`" % [part, path])
      break
    elif proto.kind == Marker:
      result.data.writeVarint(cast[uint](proto.code))
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
