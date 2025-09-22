{.used.}

import results, unittest
import ../../libp2p/peerid
import ../../libp2p/protocols/mix/[serialization, fragmentation]

suite "Fragmentation":
  let peerId =
    PeerId.init("16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC").get()

  test "serialize and deserialize message chunk":
    let
      message = newSeq[byte](DataSize)
      chunks = padAndChunkMessage(message, peerId)
      serialized = chunks[0].serialize()
      deserialized =
        MessageChunk.deserialize(serialized).expect("Deserialization error")

    check chunks[0] == deserialized

  test "pad and unpad small message":
    let
      message = cast[seq[byte]]("Hello, World!")
      messageBytesLen = len(message)
      paddedMsg = addPadding(message, peerId)
      unpaddedMessage = removePadding(paddedMsg).expect("Unpad error")

    let (paddingLength, data, _) = paddedMsg.get()

    check:
      paddingLength == uint16(DataSize - messageBytesLen)
      data.len == DataSize
      unpaddedMessage.len == messageBytesLen

  test "pad and chunk large message":
    let
      message = newSeq[byte](MessageSize * 2 + (MessageSize - 1))
      messageBytesLen = len(message)
      chunks = padAndChunkMessage(message, peerId)
      totalChunks = max(1, ceilDiv(messageBytesLen, DataSize))

    check chunks.len == totalChunks

    for i in 0 ..< totalChunks:
      let (paddingLength, data, _) = chunks[i].get()
      if i != totalChunks - 1:
        check paddingLength == 0
      else:
        let chunkSize = messageBytesLen mod DataSize
        check paddingLength == uint16(DataSize - chunkSize)

      check data.len == DataSize

  test "chunk sequence numbers are consecutive":
    let
      message = newSeq[byte](MessageSize * 3)
      messageBytesLen = len(message)
      chunks = padAndChunkMessage(message, peerId)
      totalChunks = max(1, ceilDiv(messageBytesLen, DataSize))

    check chunks.len == totalChunks

    let (_, _, firstSeqNo) = chunks[0].get()

    for i in 1 ..< totalChunks:
      let (_, _, seqNo) = chunks[i].get()
      check seqNo == firstSeqNo + uint32(i)

  test "chunk data reconstructs original message":
    let
      message = cast[seq[byte]]("This is a test message that will be split into multiple chunks.")
      chunks = padAndChunkMessage(message, peerId)

    var reconstructed: seq[byte]
    for chunk in chunks:
      let (paddingLength, data, _) = chunk.get()
      reconstructed.add(data[paddingLength.int ..^ 1])

    check reconstructed == message

  test "empty message handling":
    let
      message = cast[seq[byte]]("")
      chunks = padAndChunkMessage(message, peerId)

    check chunks.len == 1

    let (paddingLength, _, _) = chunks[0].get()

    check paddingLength == uint16(DataSize)

  test "message size equal to chunk size":
    let
      message = newSeq[byte](DataSize)
      chunks = padAndChunkMessage(message, peerId)

    check chunks.len == 1

    let (paddingLength, _, _) = chunks[0].get()

    check paddingLength == 0
