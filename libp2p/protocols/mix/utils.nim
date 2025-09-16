import results, strutils
import stew/base58
import ./serialization

const peerIdByteLen = 39

proc bytesToUInt16*(data: openArray[byte]): Result[uint16, string] =
  if len(data) != 2:
    return err("Data must be exactly 2 bytes long to convert to uint16")
  return ok(uint16(data[0]) shl 8 or uint16(data[1]))

proc uint16ToBytes*(value: uint16): seq[byte] =
  return @[byte(value shr 8), byte(value and 0xFF)]

proc bytesToUInt32*(data: openArray[byte]): Result[uint32, string] =
  if len(data) != 4:
    return err("Data must be exactly 4 bytes long to convert to uint32")
  return ok(
    uint32(data[0]) shl 24 or uint32(data[1]) shl 16 or uint32(data[2]) shl 8 or
      uint32(data[3])
  )

proc uint32ToBytes*(value: uint32): seq[byte] =
  return
    @[
      byte(value shr 24),
      byte(value shr 16 and 0xFF),
      byte(value shr 8 and 0xFF),
      byte(value and 0xFF),
    ]

proc extractPeerId(parts: seq[string], index: int): Result[seq[byte], string] =
  if parts[index - 1] != "p2p":
    return err("Invalid peerId component")
  let peerIdBase58 = parts[index]
  if peerIdBase58.len != 53:
    return err("Peer ID must be exactly 53 characters")
  try:
    let peerIdBytes = Base58.decode(peerIdBase58)
    if peerIdBytes.len != peerIdByteLen:
      return err("Peer ID must be exactly " & $peerIdByteLen & " bytes")
    return ok(peerIdBytes)
  except Base58Error:
    return err("Invalid Peer ID")

proc multiAddrToBytes*(multiAddr: string): Result[seq[byte], string] =
  var
    parts = multiAddr.split('/')
    res: seq[byte] = @[]

  const minMultiAddrComponentLen = 7
  const maxMultiAddrComponentLen = 11

  if not (
    parts.len >= minMultiAddrComponentLen and parts.len <= maxMultiAddrComponentLen
  ):
    return err("Invalid multiaddress format")

  if parts[1] != "ip4":
    # ToDo: Add support for ipv6. Supporting ipv4 only for testing purposes
    return err("Only ip4 addresses are supported")

  # IP address (4 bytes) 
  let ipParts = parts[2].split('.')
  if ipParts.len != 4:
    return err("Invalid IP address format")
  for part in ipParts:
    try:
      let ipPart = parseInt(part)
      if ipPart < 0 or ipPart > 255:
        return err("Invalid IP address format")
      res.add(byte(ipPart))
    except ValueError:
      return err("Invalid IP address format")

  # Protocol (1 byte) ToDo: TLS or QUIC
  var isQuic = false
  if parts[3] != "tcp" and not (parts[3] == "udp" and parts[5] == "quic-v1"):
    return err("Unsupported protocol")
  res.add(
    if parts[3] == "tcp":
      byte(0)
    else:
      isQuic = true
      byte(1)
  ) # Using TCP for testing purposes

  # Port (2 bytes)
  try:
    let port = parseInt(parts[4])
    if port < 0 or port > 65535:
      return err("Invalid port")
    res.add(uint16ToBytes(uint16(port)))
  except ValueError:
    return err("Invalid port")

  # PeerID (39 bytes),  if using circuit relay, this represents the relay server
  let peerId1Bytes = ?extractPeerId(parts, if isQuic: 7 else: 6)
  res.add(peerId1Bytes)

  if parts.len > minMultiAddrComponentLen + (if isQuic: 1 else: 0):
    if not (
      parts.len == maxMultiAddrComponentLen - 1 or
      (isQuic and parts.len == maxMultiAddrComponentLen)
    ):
      return err("invalid p2p circuit relay multiaddress")
    elif not (parts[if isQuic: 8 else: 7] == "p2p-circuit"):
      return err("Invalid p2p-circuit component")

    let peerId2Bytes = ?extractPeerId(parts, if isQuic: 10 else: 9)
    res.add(peerId2Bytes)

  if res.len > AddrSize:
    return err("Address must be <= " & $AddrSize & " bytes")

  return ok(res & newSeq[byte](AddrSize - res.len))

proc bytesToMultiAddr*(bytes: openArray[byte]): Result[string, string] =
  if bytes.len != AddrSize:
    return err("Address must be exactly " & $AddrSize & " bytes")

  var ipParts: seq[string] = @[]
  for i in 0 .. 3:
    ipParts.add($bytes[i])
      # ToDo: Add support for ipv6. Supporting ipv4 only for testing purposes

  let protocol = if bytes[4] == 0: "tcp" else: "udp"

  let quic = if bytes[4] == 1: "/quic-v1" else: ""

    # ToDo: TLS or QUIC (Using TCP for testing purposes)

  let port = bytesToUInt16(bytes[5 .. 6]).valueOr:
    return err("Error in conversion of bytes to port no.: " & error)

  let peerId1 = "/p2p/" & Base58.encode(bytes[7 ..< 46])

  let peerId2Bytes = bytes[7 + peerIdByteLen ..< 7 + (peerIdByteLen * 2)]
  let peerId2 =
    if peerId2Bytes != newSeq[byte](peerIdByteLen):
      "/p2p-circuit/p2p/" & Base58.encode(peerId2Bytes)
    else:
      ""

  return ok(
    "/ip4/" & ipParts.join(".") & "/" & protocol & "/" & $port & quic & peerId1 & peerId2
  )
