import results
import std/sequtils
import ../../utility

const
  k* = 16 # Security parameter
  r* = 5 # Maximum path length
  t* = 6 # t.k - combined length of next hop address and delay
  AlphaSize* = 32 # Group element
  BetaSize* = ((r * (t + 1)) + 1) * k # bytes
  GammaSize* = 16 # Output of HMAC-SHA-256, truncated to 16 bytes
  HeaderSize* = AlphaSize + BetaSize + GammaSize # Total header size
  DelaySize* = 2 # Delay size
  AddrSize* = (t * k) - DelaySize # Address size
  PacketSize* = 4608 # Total packet size (from spec)
  MessageSize* = PacketSize - HeaderSize - k # Size of the message itself
  PayloadSize* = MessageSize + k # Total payload size
  SurbSize* = HeaderSize + AddrSize + k
    # Size of a surb packet inside the message payload
  SurbLenSize* = 1 # Size of the field storing the number of surbs
  SurbIdLen* = k # Size of the identifier used when sending a message with surb

type Header* = object
  Alpha*: seq[byte]
  Beta*: seq[byte]
  Gamma*: seq[byte]

proc init*(
    T: typedesc[Header], alpha: seq[byte], beta: seq[byte], gamma: seq[byte]
): T =
  return T(Alpha: alpha, Beta: beta, Gamma: gamma)

proc get*(header: Header): (seq[byte], seq[byte], seq[byte]) =
  (header.Alpha, header.Beta, header.Gamma)

proc serialize*(header: Header): seq[byte] =
  doAssert header.Alpha.len == AlphaSize,
    "Alpha must be exactly " & $AlphaSize & " bytes"
  doAssert header.Beta.len == BetaSize, "Beta must be exactly " & $BetaSize & " bytes"
  doAssert header.Gamma.len == GammaSize,
    "Gamma must be exactly " & $GammaSize & " bytes"
  return header.Alpha & header.Beta & header.Gamma

proc deserialize*(
    T: typedesc[Header], serializedHeader: openArray[byte]
): Result[T, string] =
  if len(serializedHeader) < HeaderSize:
    return err("Serialized header must be exactly " & $HeaderSize & " bytes")

  let header = Header(
    Alpha: serializedHeader[0 .. (AlphaSize - 1)],
    Beta: serializedHeader[AlphaSize .. (AlphaSize + BetaSize - 1)],
    Gamma: serializedHeader[(AlphaSize + BetaSize) .. (HeaderSize - 1)],
  )

  ok(header)

type Message* = seq[byte]

proc serialize*(message: Message): seq[byte] =
  doAssert message.len() == MessageSize,
    "Message must be exactly " & $(MessageSize) & " bytes"

  var res = newSeq[byte](k) # Prepend k bytes of zero padding
  res.add(message)
  return res

proc deserialize*(
    T: typedesc[Message], serializedMessage: openArray[byte]
): Result[T, string] =
  if len(serializedMessage) != PayloadSize:
    return err("Serialized message must be exactly " & $PayloadSize & " bytes")
  return ok(serializedMessage[k ..^ 1])

type Hop* = object
  MultiAddress: seq[byte]

proc init*(T: typedesc[Hop], multiAddress: seq[byte]): T =
  T(
    MultiAddress:
      if multiAddress == newSeq[byte](AddrSize):
        @[]
      else:
        multiAddress
  )

proc get*(hop: Hop): seq[byte] =
  return hop.MultiAddress

proc serialize*(hop: Hop): seq[byte] =
  if hop.MultiAddress.len == 0:
    return newSeq[byte](AddrSize)

  doAssert len(hop.MultiAddress) == AddrSize,
    "MultiAddress must be exactly " & $AddrSize & " bytes"

  return hop.MultiAddress

proc deserialize*(T: typedesc[Hop], data: openArray[byte]): Result[T, string] =
  if len(data) != AddrSize:
    return err("MultiAddress must be exactly " & $AddrSize & " bytes")
  ok(
    T(
      MultiAddress:
        if data == newSeq[byte](AddrSize):
          @[]
        else:
          @data
    )
  )

type RoutingInfo* = object
  Addr: Hop
  Delay: seq[byte]
  Gamma: seq[byte]
  Beta: seq[byte]

proc init*(
    T: typedesc[RoutingInfo],
    address: Hop,
    delay: seq[byte],
    gamma: seq[byte],
    beta: seq[byte],
): T =
  return T(Addr: address, Delay: delay, Gamma: gamma, Beta: beta)

proc getRoutingInfo*(info: RoutingInfo): (Hop, seq[byte], seq[byte], seq[byte]) =
  (info.Addr, info.Delay, info.Gamma, info.Beta)

proc serialize*(info: RoutingInfo): seq[byte] =
  doAssert info.Delay.len() == DelaySize,
    "Delay must be exactly " & $DelaySize & " bytes"
  doAssert info.Gamma.len() == GammaSize,
    "Gamma must be exactly " & $GammaSize & " bytes"
  let expectedBetaLen = ((r * (t + 1)) - t) * k
  doAssert info.Beta.len() == expectedBetaLen,
    "Beta must be exactly " & $expectedBetaLen & " bytes"

  let addrBytes = info.Addr.serialize()

  return addrBytes & info.Delay & info.Gamma & info.Beta

proc readBytes(
    data: openArray[byte], offset: var int, readSize: Opt[int] = Opt.none(int)
): Result[seq[byte], string] =
  if data.len < offset:
    return err("not enough data")

  readSize.withValue(size):
    if data.len < offset + size:
      return err("not enough data")
    let slice = data[offset ..< offset + size]
    offset += size
    return ok(slice)

  let slice = data[offset .. ^1]
  offset = data.len
  return ok(slice)

proc deserialize*(T: typedesc[RoutingInfo], data: openArray[byte]): Result[T, string] =
  if len(data) != BetaSize + ((t + 1) * k):
    return err("Data must be exactly " & $(BetaSize + ((t + 1) * k)) & " bytes")

  let hop = Hop.deserialize(data[0 .. AddrSize - 1]).valueOr:
    return err("Deserialize hop error: " & error)

  var offset: int = AddrSize
  return ok(
    RoutingInfo(
      Addr: hop,
      Delay: ?data.readBytes(offset, Opt.some(DelaySize)),
      Gamma: ?data.readBytes(offset, Opt.some(GammaSize)),
      Beta: ?data.readBytes(offset, Opt.some(BetaSize)),
    )
  )

type SphinxPacket* = object
  Hdr*: Header
  Payload*: seq[byte]

proc init*(T: typedesc[SphinxPacket], header: Header, payload: seq[byte]): T =
  T(Hdr: header, Payload: payload)

proc get*(packet: SphinxPacket): (Header, seq[byte]) =
  (packet.Hdr, packet.Payload)

proc serialize*(packet: SphinxPacket): seq[byte] =
  let headerBytes = packet.Hdr.serialize()
  return headerBytes & packet.Payload

proc deserialize*(T: typedesc[SphinxPacket], data: openArray[byte]): Result[T, string] =
  if len(data) != PacketSize:
    return err("Sphinx packet size must be exactly " & $PacketSize & " bytes")

  let header = ?Header.deserialize(data)

  return ok(SphinxPacket(Hdr: header, Payload: data[HeaderSize ..^ 1]))

type
  Secret* = seq[seq[byte]]

  Key* = seq[byte]

  SURBIdentifier* = array[SurbIdLen, byte]

  SURB* = object
    hop*: Hop
    header*: Header
    key*: Key
    secret*: Opt[Secret]

proc serializeMessageWithSURBs*(
    msg: seq[byte], surbs: seq[SURB]
): Result[seq[byte], string] =
  if surbs.len > (MessageSize - SurbLenSize - 1) div SurbSize:
    return err("too many SURBs")

  let surbBytes =
    surbs.mapIt(it.hop.serialize() & it.header.serialize() & it.key).concat()
  ok(byte(surbs.len) & surbBytes & msg)

proc extractSURBs*(msg: seq[byte]): Result[(seq[SURB], seq[byte]), string] =
  var offset = 0
  let surbsLenBytes = ?readBytes(msg, offset, Opt.some(1))
  let surbsLen = int(surbsLenBytes[0])

  if surbsLen > (MessageSize - SurbLenSize - 1) div SurbSize:
    return err("too many SURBs")

  var surbs: seq[SURB] = newSeq[SURB](surbsLen)
  for i in 0 ..< surbsLen:
    let hopBytes = ?readBytes(msg, offset, Opt.some(AddrSize))
    let headerBytes = ?readBytes(msg, offset, Opt.some(HeaderSize))
    surbs[i].hop = ?Hop.deserialize(hopBytes)
    surbs[i].header = ?Header.deserialize(headerBytes)
    surbs[i].key = ?readBytes(msg, offset, Opt.some(k))
  let msg = ?readBytes(msg, offset)
  return ok((surbs, msg))
