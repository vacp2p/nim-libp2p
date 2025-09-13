{.used.}

import chronicles, random, results, unittest
import
  ../../libp2p/protocols/mix/[config, curve25519, serialization, sphinx, tag_manager]
import bearssl/rand

# Helper function to pad/truncate message
proc padMessage(message: openArray[byte], size: int): seq[byte] =
  if message.len >= size:
    return message[0 .. size - 1] # Truncate if larger
  else:
    result = @message
    let paddingLength = size - message.len
    result.add(newSeq[byte](paddingLength)) # Pad with zeros

# Helper function to create dummy data
proc createDummyData(): (
  Message, seq[FieldElement], seq[FieldElement], seq[seq[byte]], seq[Hop], Hop
) =
  var keyPairResult = generateKeyPair()
  if keyPairResult.isErr:
    error "Generate key pair error", err = keyPairResult.error
    fail()
  let (privateKey1, publicKey1) = keyPairResult.get()

  keyPairResult = generateKeyPair()
  if keyPairResult.isErr:
    error "Generate key pair error", err = keyPairResult.error
    fail()
  let (privateKey2, publicKey2) = keyPairResult.get()

  keyPairResult = generateKeyPair()
  if keyPairResult.isErr:
    error "Generate key pair error", err = keyPairResult.error
    fail()
  let (privateKey3, publicKey3) = keyPairResult.get()

  let
    privateKeys = @[privateKey1, privateKey2, privateKey3]
    publicKeys = @[publicKey1, publicKey2, publicKey3]

    delay = @[newSeq[byte](delaySize), newSeq[byte](delaySize), newSeq[byte](delaySize)]

    hops =
      @[
        Hop.init(newSeq[byte](addrSize)),
        Hop.init(newSeq[byte](addrSize)),
        Hop.init(newSeq[byte](addrSize)),
      ]

    message = Message.init(newSeq[byte](messageSize))
    dest = Hop.init(newSeq[byte](addrSize))
  return (message, privateKeys, publicKeys, delay, hops, dest)

proc randomI(): I =
  let rng = HmacDrbgContext.new()
  if rng.isNil:
    doAssert false, "Failed to creat HmacDrbgContext with system randomness"
  var id: I
  hmacDrbgGenerate(rng[], id)
  return id

# Unit tests for sphinx.nim
suite "Sphinx Tests":
  var tm: TagManager

  setup:
    tm = TagManager.new()

  teardown:
    clearTags(tm)

  test "sphinx_wrap_and_process":
    let (message, privateKeys, publicKeys, delay, hops, dest) = createDummyData()

    let packetBytesRes = wrapInSphinxPacket(message, publicKeys, delay, hops, dest)
    if packetBytesRes.isErr:
      error "Sphinx wrap error", err = packetBytesRes.error
      fail()
    let packetBytes = packetBytesRes.get()

    if packetBytes.len != packetSize:
      error "Packet length is not valid",
        pkt_len = $(packetBytes.len), expected_len = $packetSize
      fail()

    let packetRes = SphinxPacket.deserialize(packetBytes)
    if packetRes.isErr:
      error "Sphinx wrap error", err = packetBytesRes.error
      fail()
    let packet = packetRes.get()

    let res1 = processSphinxPacket(packet, privateKeys[0], tm)
    if res1.isErr:
      error "Error in Sphinx processing", err = res1.error
      fail()
    let processedSP1 = res1.get()

    if processedSP1.status != Intermediate:
      error "Processing status should be Intermediate"
      fail()

    if processedSP1.serializedSphinxPacket.len != packetSize:
      error "Packet length is not valid",
        pkt_len = $(processedSP1.serializedSphinxPacket.len), expected_len = $packetSize
      fail()

    let processedPacket1Res =
      SphinxPacket.deserialize(processedSP1.serializedSphinxPacket)
    if processedPacket1Res.isErr:
      error "Sphinx wrap error", err = processedPacket1Res.error
      fail()
    let processedPacket1 = processedPacket1Res.get()

    let res2 = processSphinxPacket(processedPacket1, privateKeys[1], tm)
    if res2.isErr:
      error "Error in Sphinx processing", err = res2.error
      fail()
    let processedSP2 = res2.get()

    if processedSP2.status != Intermediate:
      error "Processing status should be Intermediate"
      fail()

    if processedSP2.serializedSphinxPacket.len != packetSize:
      error "Packet length is not valid",
        pkt_len = $(processedSP2.serializedSphinxPacket.len), expected_len = $packetSize
      fail()

    let processedPacket2Res =
      SphinxPacket.deserialize(processedSP2.serializedSphinxPacket)
    if processedPacket2Res.isErr:
      error "Sphinx wrap error", err = processedPacket2Res.error
      fail()
    let processedPacket2 = processedPacket2Res.get()

    let res3 = processSphinxPacket(processedPacket2, privateKeys[2], tm)
    if res3.isErr:
      error "Error in Sphinx processing", err = res3.error
      fail()
    let processedSP3 = res3.get()

    if processedSP3.status != Exit:
      error "Processing status should be Exit", status = processedSP3.status
      fail()

    if processedSP3.messageChunk != message.getContent():
      error "Packet processing failed"
      fail()

  test "sphinx_wrap_empty_public_keys":
    let (message, _, _, delay, _, dest) = createDummyData()

    let packetRes = wrapInSphinxPacket(message, @[], delay, @[], dest)
    if packetRes.isOk:
      error "Expected Sphinx wrap error when public keys are empty, but got success"
      fail()

  test "sphinx_process_invalid_mac":
    let (message, privateKeys, publicKeys, delay, hops, dest) = createDummyData()

    let packetBytesRes = wrapInSphinxPacket(message, publicKeys, delay, hops, dest)
    if packetBytesRes.isErr:
      error "Sphinx wrap error", err = packetBytesRes.error
    let packetBytes = packetBytesRes.get()

    if packetBytes.len != packetSize:
      error "Packet length is not valid",
        pkt_len = $(packetBytes.len), expected_len = $packetSize
      fail()

    # Corrupt the MAC for testing
    var tamperedPacketBytes = packetBytes
    tamperedPacketBytes[0] = packetBytes[0] xor 0x01

    let tamperedPacketRes = SphinxPacket.deserialize(tamperedPacketBytes)
    if tamperedPacketRes.isErr:
      error "Sphinx wrap error", err = tamperedPacketRes.error
      fail()
    let tamperedPacket = tamperedPacketRes.get()

    let res = processSphinxPacket(tamperedPacket, privateKeys[0], tm)
    if res.isErr:
      error "Error in Sphinx processing", err = res.error
      fail()
    let invalidMacPkt = res.get()

    if invalidMacPkt.status != InvalidMAC:
      error "Processing status should be InvalidMAC"
      fail()

  test "sphinx_process_duplicate_tag":
    let (message, privateKeys, publicKeys, delay, hops, dest) = createDummyData()

    let packetBytesRes = wrapInSphinxPacket(message, publicKeys, delay, hops, dest)
    if packetBytesRes.isErr:
      error "Sphinx wrap error", err = packetBytesRes.error
    let packetBytes = packetBytesRes.get()

    if packetBytes.len != packetSize:
      error "Packet length is not valid",
        pkt_len = $(packetBytes.len), expected_len = $packetSize
      fail()

    let packetRes = SphinxPacket.deserialize(packetBytes)
    if packetRes.isErr:
      error "Sphinx wrap error", err = packetRes.error
      fail()
    let packet = packetRes.get()

    # Process the packet twice to test duplicate tag handling
    let res1 = processSphinxPacket(packet, privateKeys[0], tm)
    if res1.isErr:
      error "Error in Sphinx processing", err = res1.error
      fail()
    let processedSP1 = res1.get()

    if processedSP1.status != Intermediate:
      error "Processing status should be Intermediate"
      fail()

    let res2 = processSphinxPacket(packet, privateKeys[0], tm)
    if res2.isErr:
      error "Error in Sphinx processing", err = res2.error
      fail()
    let processedSP2 = res2.get()

    if processedSP2.status != Duplicate:
      error "Processing status should be Duplicate"
      fail()

  test "sphinx_wrap_and_process_message_sizes":
    let messageSizes = @[32, 64, 128, 256, 512]
    for size in messageSizes:
      let (_, privateKeys, publicKeys, delay, hops, dest) = createDummyData()
      var message = newSeq[byte](size)
      randomize()
      for i in 0 ..< size:
        message[i] = byte(rand(256))
      let paddedMessage = padMessage(message, messageSize)

      let packetResBytes =
        wrapInSphinxPacket(Message.init(paddedMessage), publicKeys, delay, hops, dest)
      if packetResBytes.isErr:
        error "Sphinx wrap error", err = packetResBytes.error
      let packetBytes = packetResBytes.get()

      if packetBytes.len != packetSize:
        error "Packet length is not valid",
          pkt_len = $(packetBytes.len),
          expected_len = $packetSize,
          msg_len = $messageSize
        fail()

      let packetRes = SphinxPacket.deserialize(packetBytes)
      if packetRes.isErr:
        error "Sphinx wrap error", err = packetRes.error
        fail()
      let packet = packetRes.get()

      let res1 = processSphinxPacket(packet, privateKeys[0], tm)
      if res1.isErr:
        error "Error in Sphinx processing", err = res1.error
        fail()
      let processedSP1 = res1.get()

      if processedSP1.status != Intermediate:
        error "Processing status should be Intermediate"
        fail()

      if processedSP1.serializedSphinxPacket.len != packetSize:
        error "Packet length is not valid",
          pkt_len = $(processedSP1.serializedSphinxPacket.len),
          expected_len = $packetSize
        fail()

      let processedPacket1Res =
        SphinxPacket.deserialize(processedSP1.serializedSphinxPacket)
      if processedPacket1Res.isErr:
        error "Sphinx wrap error", err = processedPacket1Res.error
        fail()
      let processedPacket1 = processedPacket1Res.get()

      let res2 = processSphinxPacket(processedPacket1, privateKeys[1], tm)
      if res2.isErr:
        error "Error in Sphinx processing", err = res2.error
        fail()
      let processedSP2 = res2.get()

      if processedSP2.status != Intermediate:
        error "Processing status should be Intermediate"
        fail()

      if processedSP2.serializedSphinxPacket.len != packetSize:
        error "Packet length is not valid",
          pkt_len = $(processedSP2.serializedSphinxPacket.len),
          expected_len = $packetSize
        fail()

      let processedPacket2Res =
        SphinxPacket.deserialize(processedSP2.serializedSphinxPacket)
      if processedPacket2Res.isErr:
        error "Sphinx wrap error", err = processedPacket2Res.error
        fail()
      let processedPacket2 = processedPacket2Res.get()

      let res3 = processSphinxPacket(processedPacket2, privateKeys[2], tm)
      if res3.isErr:
        error "Error in Sphinx processing", err = res3.error
        fail()
      let processedSP3 = res3.get()

      if processedSP3.status != Exit:
        error "Processing status should be Exit"
        fail()

      if processedSP3.messageChunk != paddedMessage:
        error "Packet processing failed"
        fail()
