import results, sugar, sequtils, strutils
import ./serialization
import stew/endians2
import ../../[multicodec, multiaddress, peerid]

const
  PeerIdByteLen = 39 # ed25519 and secp256k1 multihash length
  MinMultiAddrComponentLen = 2
  MaxMultiAddrComponentLen = 5 # quic + circuit relay

# TODO: Add support for ipv6, dns, dns4,  ws/wss/sni support

proc multiAddrToBytes*(
    peerId: PeerId, multiAddr: MultiAddress
): Result[seq[byte], string] {.raises: [].} =
  var ma = multiAddr
  let sma = multiAddr.items().toSeq()
  var res: seq[byte] = @[]

  if not (sma.len >= MinMultiAddrComponentLen and sma.len <= MaxMultiAddrComponentLen):
    return err("Invalid multiaddress format")

  # Only IPV4 is supported
  let isCircuitRelay = ?ma.contains(multiCodec("p2p-circuit"))
  let baseP2PEndIdx = if isCircuitRelay: 3 else: 1
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

  if isCircuitRelay:
    let relayIdPart = ?ma.getPart(multiCodec("p2p"))
    let relayId = ?PeerId.init(?relayIdPart.protoArgument()).mapErr(x => $x)
    if relayId.data.len != PeerIdByteLen:
      return err("unsupported PeerId key type, only Secp256k1 keys are supported")
    res.add(relayId.data)

  # PeerID (39 bytes)
  if peerId.data.len != PeerIdByteLen:
    return err("Unsupported PeerId key type, only Secp256k1 keys are supported")
  res.add(peerId.data)

  if res.len > AddrSize:
    return err("Address must be <= " & $AddrSize & " bytes")

  return ok(res & newSeq[byte](AddrSize - res.len))

proc bytesToMultiAddr*(bytes: openArray[byte]): MaResult[(PeerId, MultiAddress)] =
  if bytes.len != AddrSize:
    return err("Address must be exactly " & $AddrSize & " bytes")

  let
    ip = bytes[0 .. 3].mapIt($it).join(".")
    protocol = if bytes[4] == 0: "tcp" else: "udp"
    quic = if bytes[4] == 1: "/quic-v1" else: ""
    port = uint16.fromBytesBE(bytes[5 .. 6])
    # peerId1 represents the circuit relay server addr if p2p-circuit addr, otherwise it's the node's actual peerId
    peerId1Bytes = bytes[7 ..< 46]
    peerId2Bytes = bytes[7 + PeerIdByteLen ..< 7 + (PeerIdByteLen * 2)]

  let ma = ?MultiAddress.init("/ip4/" & ip & "/" & protocol & "/" & $port & quic)

  return
    if peerId2Bytes != newSeq[byte](PeerIdByteLen):
      # Has circuit relay address
      let relayIdMa = ?MultiAddress.init(multiCodec("p2p"), peerId1Bytes)
      let p2pCircuitMa = ?MultiAddress.init(multiCodec("p2p-circuit"))
      let peerId = ?PeerId.init(peerId2Bytes).mapErr(x => $x)
      ok((peerId, ?(ma & relayIdMa & p2pCircuitMa).catch().mapErr(x => x.msg)))
    else:
      let peerId = ?PeerId.init(peerId1Bytes).mapErr(x => $x)
      ok((peerId, ma))
