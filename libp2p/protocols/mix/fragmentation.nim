import ./[serialization, seqno_generator]
import results, stew/endians2
import ../../peerid

const PaddingLengthSize* = 2
const SeqNoSize* = 4
const DataSize* = MessageSize - PaddingLengthSize - SeqNoSize

# Unpadding and reassembling messages will be handled by the top-level applications.
# Although padding and splitting messages could also be managed at that level, we 
# implement it here to clarify the sender's logic.
# This is crucial as the sender is responsible for wrapping messages in Sphinx packets.

type MessageChunk* = object
  paddingLength: uint16
  data: seq[byte]
  seqNo: uint32

proc init*(
    T: typedesc[MessageChunk], paddingLength: uint16, data: seq[byte], seqNo: uint32
): T =
  T(paddingLength: paddingLength, data: data, seqNo: seqNo)

proc get*(msgChunk: MessageChunk): (uint16, seq[byte], uint32) =
  (msgChunk.paddingLength, msgChunk.data, msgChunk.seqNo)

proc serialize*(msgChunk: MessageChunk): seq[byte] =
  let
    paddingBytes = msgChunk.paddingLength.toBytesBE()
    seqNoBytes = msgChunk.seqNo.toBytesBE()

  doAssert msgChunk.data.len == DataSize,
    "Padded data must be exactly " & $DataSize & " bytes"

  return @paddingBytes & msgChunk.data & @seqNoBytes

proc deserialize*(T: typedesc[MessageChunk], data: openArray[byte]): Result[T, string] =
  if data.len != MessageSize:
    return err("Data must be exactly " & $MessageSize & " bytes")

  let
    paddingLength = uint16.fromBytesBE(data[0 .. PaddingLengthSize - 1])
    chunk = data[PaddingLengthSize .. (PaddingLengthSize + DataSize - 1)]
    seqNo = uint32.fromBytesBE(data[PaddingLengthSize + DataSize ..^ 1])

  ok(T(paddingLength: paddingLength, data: chunk, seqNo: seqNo))

proc ceilDiv*(a, b: int): int =
  (a + b - 1) div b

proc addPadding*(messageBytes: seq[byte], seqNo: SeqNo): MessageChunk =
  ## Pads messages smaller than DataSize
  let paddingLength = uint16(DataSize - messageBytes.len)
  let paddedData =
    if paddingLength > 0:
      let paddingBytes = newSeq[byte](paddingLength)
      paddingBytes & messageBytes
    else:
      messageBytes
  MessageChunk(paddingLength: paddingLength, data: paddedData, seqNo: seqNo)

proc addPadding*(messageBytes: seq[byte], peerId: PeerId): MessageChunk =
  ## Pads messages smaller than DataSize
  var seqNoGen = SeqNo.init(peerId)
  seqNoGen.generate(messageBytes)
  messageBytes.addPadding(seqNoGen)

proc removePadding*(msgChunk: MessageChunk): Result[seq[byte], string] =
  let msgLength = len(msgChunk.data) - int(msgChunk.paddingLength)
  if msgLength < 0:
    return err("Invalid padding length")

  ok(msgChunk.data[msgChunk.paddingLength ..^ 1])

proc padAndChunkMessage*(messageBytes: seq[byte], peerId: PeerId): seq[MessageChunk] =
  var seqNoGen = SeqNo.init(peerId)
  seqNoGen.generate(messageBytes)

  var chunks: seq[MessageChunk] = @[]

  # Split to chunks
  let totalChunks = max(1, ceilDiv(messageBytes.len, DataSize))
    # Ensure at least one chunk is generated
  for i in 0 ..< totalChunks:
    let
      startIdx = i * DataSize
      endIdx = min(startIdx + DataSize, messageBytes.len)
      chunkData = messageBytes[startIdx .. endIdx - 1]
      msgChunk = chunkData.addPadding(seqNoGen)

    chunks.add(msgChunk)

    seqNoGen.inc()

  return chunks
