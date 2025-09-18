import results, sugar, sequtils, strutils
import ./serialization
import stew/[base58, endians2]
import ../../[multicodec, multiaddress, peerid]

const
  PeerIdByteLen = 39 # ed25519 and secp256k1 multihash length
  MinMultiAddrComponentLen = 3
  MaxMultiAddrComponentLen = 6 # quic + circuit relay

# TODO: Add support for ipv6, dns, dns4,  ws/wss/sni support

proc multiAddrToBytes*(
    multiAddr: MultiAddress
): Result[seq[byte], string] {.raises: [].} =
  var ma = multiAddr
  let sma = multiAddr.items().toSeq()
  var res: seq[byte] = @[]

  if not (sma.len >= MinMultiAddrComponentLen and sma.len <= MaxMultiAddrComponentLen):
    return err("Invalid multiaddress format")

  # Only IPV4 is supported
  let isCircuitRelay = ?ma.contains(multiCodec("p2p-circuit"))
  let baseP2PEndIdx = if isCircuitRelay: 4 else: 2
  let baseAddr =
    try:
      if sma.len - 1 - baseP2PEndIdx < 0:
        return err("Invalid multiaddress format")
      sma[0 .. sma.len - baseP2PEndIdx].mapIt(it.tryGet()).foldl(a & b)
    except LPError as exc:
      return err("Could not obtain base address: " & exc.msg)

  let isQuic = QUIC_V1_IP.match(baseAddr)
  let isTCP = TCP_IP.match(baseAddr)

  if not (isTCP or isQuic):
    return err("Unsupported protocol")

  # 4 bytes for the IP
  let ip = ?ma.getPart(multiCodec("ip4")).value().protoArgument()
  res.add(ip)

  var port: string
  if isQuic:
    res.add(1.byte) # Protocol byte
    let udpPortPart = ma.getPart(multiCodec("udp")).value()
    port = $udpPortPart
  elif isTCP:
    res.add(0.byte) # Protocol byte
    let tcpPortPart = ma.getPart(multiCodec("tcp")).value()
    port = $tcpPortPart
  let portNum = ?catch(port.split('/')[2].parseInt()).mapErr(x => x.msg)
  res.add(portNum.uint16.toBytesBE())

  # PeerID (39 bytes),  if using circuit relay, this represents the relay server
  let p2pPart = ?ma.getPart(multiCodec("p2p"))
  let peerId = ?PeerId.init(?p2pPart.protoArgument()).mapErr(x => $x)

  if peerId.data.len != PeerIdByteLen:
    return err("unsupported PeerId key type")
  res.add(peerId.data)

  if isCircuitRelay:
    let dstPart = ?sma[^1]
    let dstPeerId = ?PeerId.init(?dstPart.protoArgument()).mapErr(x => $x)
    if dstPeerId.data.len != PeerIdByteLen:
      return err("unsupported PeerId key type")
    res.add(dstPeerId.data)

  if res.len > AddrSize:
    return err("Address must be <= " & $AddrSize & " bytes")

  return ok(res & newSeq[byte](AddrSize - res.len))

proc bytesToMultiAddr*(bytes: openArray[byte]): Result[MultiAddress, string] =
  if bytes.len != AddrSize:
    return err("Address must be exactly " & $AddrSize & " bytes")

  let
    ip = bytes[0 .. 3].mapIt($it).join(".")
    protocol = if bytes[4] == 0: "tcp" else: "udp"
    quic = if bytes[4] == 1: "/quic-v1" else: ""
    port = uint16.fromBytesBE(bytes[5 .. 6])
    # peerId1 represents the circuit relay server addr if p2p-circuit addr, otherwise it's the node's actual peerId
    peerId1 = "/p2p/" & Base58.encode(bytes[7 ..< 46])
    peerId2Bytes = bytes[7 + PeerIdByteLen ..< 7 + (PeerIdByteLen * 2)]
    # peerId2 will contain a value only if this is a p2p-circuit address
    peerId2 =
      if peerId2Bytes != newSeq[byte](PeerIdByteLen):
        "/p2p-circuit/p2p/" & Base58.encode(peerId2Bytes)
      else:
        ""

  return MultiAddress
    .init("/ip4/" & ip & "/" & protocol & "/" & $port & quic & peerId1 & peerId2)
    .mapErr(x => $x)
