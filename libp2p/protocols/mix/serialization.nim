import results
import ./config
import std/sequtils

type Header* = object
  Alpha: seq[byte]
  Beta: seq[byte]
  Gamma: seq[byte]

proc init*(
    T: typedesc[Header], alpha: seq[byte], beta: seq[byte], gamma: seq[byte]
): T =
  return T(Alpha: alpha, Beta: beta, Gamma: gamma)

proc getHeader*(header: Header): (seq[byte], seq[byte], seq[byte]) =
  (header.Alpha, header.Beta, header.Gamma)

proc serialize*(header: Header): Result[seq[byte], string] =
  if len(header.Alpha) != alphaSize:
    return err("Alpha must be exactly " & $alphaSize & " bytes")
  if len(header.Beta) != betaSize:
    return err("Beta must be exactly " & $betaSize & " bytes")
  if len(header.Gamma) != gammaSize:
    return err("Gamma must be exactly " & $gammaSize & " bytes")
  return ok(header.Alpha & header.Beta & header.Gamma)

proc deserialize*(
    T: typedesc[Header], serializedHeader: openArray[byte]
): Result[T, string] =
  if len(serializedHeader) < headerSize:
    return err("Serialized header must be exactly " & $headerSize & " bytes")

  let header = Header(
    Alpha: serializedHeader[0 .. (alphaSize - 1)],
    Beta: serializedHeader[alphaSize .. (alphaSize + betaSize - 1)],
    Gamma: serializedHeader[(alphaSize + betaSize) .. (headerSize - 1)],
  )

  ok(header)

type Message* = object
  Content: seq[byte]

proc init*(T: typedesc[Message], content: seq[byte]): T =
  return T(Content: content)

proc getContent*(message: Message): seq[byte] =
  return message.Content

proc serialize*(message: Message): Result[seq[byte], string] =
  if len(message.Content) != messageSize:
    return err("Message must be exactly " & $(messageSize) & " bytes")
  var res = newSeq[byte](k) # Prepend k bytes of zero padding
  res.add(message.Content)
  return ok(res)

proc deserialize*(
    T: typedesc[Message], serializedMessage: openArray[byte]
): Result[T, string] =
  if len(serializedMessage) != payloadSize:
    return err("Serialized message must be exactly " & $payloadSize & " bytes")
  return ok(T(Content: serializedMessage[k ..^ 1]))

type Hop* = object
  MultiAddress: seq[byte]

proc init*(T: typedesc[Hop], multiAddress: seq[byte]): T =
  T(
    MultiAddress:
      if multiAddress == newSeq[byte](addrSize):
        @[]
      else:
        multiAddress
  )

proc getHop*(hop: Hop): seq[byte] =
  return hop.MultiAddress

proc serialize*(hop: Hop): Result[seq[byte], string] =
  if hop.MultiAddress.len == 0:
    return ok(newSeq[byte](addrSize))
  elif len(hop.MultiAddress) != addrSize:
    return err("MultiAddress must be exactly " & $addrSize & " bytes")
  return ok(hop.MultiAddress)

proc deserialize*(T: typedesc[Hop], data: openArray[byte]): Result[T, string] =
  if len(data) != addrSize:
    return err("MultiAddress must be exactly " & $addrSize & " bytes")
  ok(
    T(
      MultiAddress:
        if data == newSeq[byte](addrSize):
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

proc serialize*(info: RoutingInfo): Result[seq[byte], string] =
  if len(info.Delay) != delaySize:
    return err("Delay must be exactly " & $delaySize & " bytes")
  if len(info.Gamma) != gammaSize:
    return err("Gamma must be exactly " & $gammaSize & " bytes")
  if len(info.Beta) != (((r * (t + 1)) - t) * k):
    return err("Beta must be exactly " & $(((r * (t + 1)) - t) * k) & " bytes")

  let addrBytes = info.Addr.serialize().valueOr:
    return err("Serialize hop error: " & error)

  return ok(addrBytes & info.Delay & info.Gamma & info.Beta)

proc deserialize*(T: typedesc[RoutingInfo], data: openArray[byte]): Result[T, string] =
  if len(data) != betaSize + ((t + 1) * k):
    return err("Data must be exactly " & $(betaSize + ((t + 1) * k)) & " bytes")

  let hop = Hop.deserialize(data[0 .. addrSize - 1]).valueOr:
    return err("Deserialize hop error: " & error)

  return ok(
    RoutingInfo(
      Addr: hop,
      Delay: data[addrSize .. (addrSize + delaySize - 1)],
      Gamma: data[(addrSize + delaySize) .. (addrSize + delaySize + gammaSize - 1)],
      Beta:
        data[(addrSize + delaySize + gammaSize) .. (((r * (t + 1)) + t + 2) * k) - 1],
    )
  )

type SphinxPacket* = object
  Hdr*: Header
  Payload*: seq[byte]

proc init*(T: typedesc[SphinxPacket], header: Header, payload: seq[byte]): T =
  T(Hdr: header, Payload: payload)

proc getSphinxPacket*(packet: SphinxPacket): (Header, seq[byte]) =
  (packet.Hdr, packet.Payload)

proc serialize*(packet: SphinxPacket): Result[seq[byte], string] =
  let headerBytes = packet.Hdr.serialize().valueOr:
    return err("Serialize sphinx packet header error: " & error)

  return ok(headerBytes & packet.Payload)

proc deserialize*(T: typedesc[SphinxPacket], data: openArray[byte]): Result[T, string] =
  if len(data) != packetSize:
    return err("Sphinx packet size must be exactly " & $packetSize & " bytes")

  let header = ?Header.deserialize(data)

  return ok(SphinxPacket(Hdr: header, Payload: data[headerSize ..^ 1]))

type
  secret* = seq[seq[byte]]

  key* = seq[byte]

  I* = array[surbIdLen, byte]

  SURB* = object
    hop*: Hop
    header*: Header
    key*: key
    secret*: Opt[secret]

proc serializeMessageWithSURBs*(
    msg: seq[byte], surbs: seq[SURB]
): Result[seq[byte], string] =
  if surbs.len > (messageSize - surbLenSize - 1) div surbSize:
    return err("too many SURBs")

  let surbBytes =
    surbs.mapIt(?it.hop.serialize() & ?it.header.serialize() & it.key).concat()
  ok(byte(surbs.len) & surbBytes & msg)

proc readBytes(
    data: seq[byte], offset: var int, dataLen: int = -1
): Result[seq[byte], string] =
  if dataLen > 0:
    if data.len < offset + dataLen:
      return err("not enough data")

    let slice = data[offset ..< offset + dataLen]
    offset += dataLen
    return ok(slice)
  elif data.len < offset:
    return err("not enough data")

  let slice = data[offset .. ^1]
  offset = data.len
  return ok(slice)

proc extractSURBs*(msg: seq[byte]): Result[(seq[SURB], seq[byte]), string] =
  var offset = 0
  let surbsLenBytes = ?readBytes(msg, offset, 1)
  let surbsLen = int(surbsLenBytes[0])

  if surbsLen > (messageSize - surbLenSize - 1) div surbSize:
    return err("too many SURBs")

  var surbs: seq[SURB] = newSeq[SURB](surbsLen)
  for i in 0 ..< surbsLen:
    let hopBytes = ?readBytes(msg, offset, addrSize)
    let headerBytes = ?readBytes(msg, offset, headerSize)
    surbs[i].hop = ?Hop.deserialize(hopBytes)
    surbs[i].header = ?Header.deserialize(headerBytes)
    surbs[i].key = ?readBytes(msg, offset, k)
  let msg = ?readBytes(msg, offset)
  return ok((surbs, msg))
