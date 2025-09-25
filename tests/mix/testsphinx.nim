{.used.}

import random, results, unittest, chronicles
import ../../libp2p/crypto/crypto
import ../../libp2p/protocols/mix/[curve25519, serialization, sphinx, tag_manager]
import bearssl/rand

# Helper function to pad/truncate message
proc addPadding(message: openArray[byte], size: int): seq[byte] =
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
  let (privateKey1, publicKey1) = generateKeyPair().expect("generate keypair error")
  let (privateKey2, publicKey2) = generateKeyPair().expect("generate keypair error")
  let (privateKey3, publicKey3) = generateKeyPair().expect("generate keypair error")

  let
    privateKeys = @[privateKey1, privateKey2, privateKey3]
    publicKeys = @[publicKey1, publicKey2, publicKey3]

    delay = @[newSeq[byte](DelaySize), newSeq[byte](DelaySize), newSeq[byte](DelaySize)]

    hops =
      @[
        Hop.init(newSeq[byte](AddrSize)),
        Hop.init(newSeq[byte](AddrSize)),
        Hop.init(newSeq[byte](AddrSize)),
      ]

    message = newSeq[byte](MessageSize)
    dest = Hop.init(newSeq[byte](AddrSize))
  return (message, privateKeys, publicKeys, delay, hops, dest)

template randomI(): SURBIdentifier =
  newRng()[].generate(SURBIdentifier)

# Unit tests for sphinx.nim
suite "Sphinx Tests":
  var tm: TagManager

  setup:
    tm = TagManager.new()

  teardown:
    clearTags(tm)

  test "sphinx wrap and process":
    let (message, privateKeys, publicKeys, delay, hops, dest) = createDummyData()

    let sp = wrapInSphinxPacket(message, publicKeys, delay, hops, dest).expect(
        "sphinx wrap error"
      )
    let packetBytes = sp.serialize()

    check packetBytes.len == PacketSize

    let packet = SphinxPacket.deserialize(packetBytes).expect("Sphinx wrap error")

    let processedSP1 =
      processSphinxPacket(packet, privateKeys[0], tm).expect("Sphinx processing error")

    check:
      processedSP1.status == Intermediate
      processedSP1.serializedSphinxPacket.len == PacketSize

    let processedPacket1 = SphinxPacket
      .deserialize(processedSP1.serializedSphinxPacket)
      .expect("Sphinx wrap error")

    let processedSP2 = processSphinxPacket(processedPacket1, privateKeys[1], tm).expect(
        "Sphinx processing error"
      )

    check:
      processedSP2.status == Intermediate
      processedSP2.serializedSphinxPacket.len == PacketSize

    let processedPacket2 = SphinxPacket
      .deserialize(processedSP2.serializedSphinxPacket)
      .expect("Sphinx wrap error")

    let processedSP3 = processSphinxPacket(processedPacket2, privateKeys[2], tm).expect(
        "Sphinx processing error"
      )

    check:
      processedSP3.status == Exit
      processedSP3.messageChunk == message

  test "sphinx wrap empty public keys":
    let (message, _, _, delay, _, dest) = createDummyData()
    check wrapInSphinxPacket(message, @[], delay, @[], dest).isErr

  test "sphinx_process_invalid_mac":
    let (message, privateKeys, publicKeys, delay, hops, dest) = createDummyData()
    let sp = wrapInSphinxPacket(message, publicKeys, delay, hops, dest).expect(
        "Sphinx wrap error"
      )
    let packetBytes = sp.serialize()

    check packetBytes.len == PacketSize

    # Corrupt the MAC for testing
    var tamperedPacketBytes = packetBytes
    tamperedPacketBytes[0] = packetBytes[0] xor 0x01

    let tamperedPacket =
      SphinxPacket.deserialize(tamperedPacketBytes).expect("Sphinx wrap error")
    let invalidMacPkt = processSphinxPacket(tamperedPacket, privateKeys[0], tm).expect(
        "Sphinx processing error"
      )

    check invalidMacPkt.status == InvalidMAC

  test "sphinx process duplicate tag":
    let (message, privateKeys, publicKeys, delay, hops, dest) = createDummyData()

    let sp = wrapInSphinxPacket(message, publicKeys, delay, hops, dest).expect(
        "Sphinx wrap error"
      )
    let packetBytes = sp.serialize()

    check packetBytes.len == PacketSize

    let packet = SphinxPacket.deserialize(packetBytes).expect("Sphinx wrap error")

    # Process the packet twice to test duplicate tag handling
    let processedSP1 =
      processSphinxPacket(packet, privateKeys[0], tm).expect("Sphinx processing error")

    check processedSP1.status == Intermediate

    let processedSP2 =
      processSphinxPacket(packet, privateKeys[0], tm).expect("Sphinx processing error")

    check processedSP2.status == Duplicate

  test "sphinx wrap and process message sizes":
    let MessageSizes = @[32, 64, 128, 256, 512]
    for size in MessageSizes:
      let (_, privateKeys, publicKeys, delay, hops, dest) = createDummyData()
      var message = newSeq[byte](size)
      randomize()
      for i in 0 ..< size:
        message[i] = byte(rand(256))
      let paddedMessage = addPadding(message, MessageSize)

      let sp = wrapInSphinxPacket(paddedMessage, publicKeys, delay, hops, dest).expect(
          "Sphinx wrap error"
        )
      let packetBytes = sp.serialize()

      check packetBytes.len == PacketSize

      let packet = SphinxPacket.deserialize(packetBytes).expect("Sphinx wrap error")

      let processedSP1 = processSphinxPacket(packet, privateKeys[0], tm).expect(
          "Sphinx processing error"
        )

      check:
        processedSP1.status == Intermediate
        processedSP1.serializedSphinxPacket.len == PacketSize

      let processedPacket1 = SphinxPacket
        .deserialize(processedSP1.serializedSphinxPacket)
        .expect("Sphinx wrap error")

      let processedSP2 = processSphinxPacket(processedPacket1, privateKeys[1], tm)
        .expect("Sphinx processing error")

      check:
        processedSP2.status == Intermediate
        processedSP2.serializedSphinxPacket.len == PacketSize

      let processedPacket2 = SphinxPacket
        .deserialize(processedSP2.serializedSphinxPacket)
        .expect("Sphinx wrap error")

      let processedSP3 = processSphinxPacket(processedPacket2, privateKeys[2], tm)
        .expect("Error in Sphinx processing")

      check:
        processedSP3.status == Exit
        processedSP3.messageChunk == paddedMessage

  test "create and use surb":
    let (message, privateKeys, publicKeys, delay, hops, _) = createDummyData()

    let surb =
      createSURB(publicKeys, delay, hops, randomI()).expect("Create SURB error")
    let packetBytes = useSURB(surb, message).serialize()

    check packetBytes.len == PacketSize

    let packet = SphinxPacket.deserialize(packetBytes).expect("Sphinx wrap error")
    let processedSP1 =
      processSphinxPacket(packet, privateKeys[0], tm).expect("Sphinx processing error")

    check:
      processedSP1.status == Intermediate
      processedSP1.serializedSphinxPacket.len == PacketSize

    let processedPacket1 = SphinxPacket
      .deserialize(processedSP1.serializedSphinxPacket)
      .expect("Sphinx wrap error")

    let processedSP2 = processSphinxPacket(processedPacket1, privateKeys[1], tm).expect(
        "Sphinx processing error"
      )

    check:
      processedSP2.status == Intermediate
      processedSP2.serializedSphinxPacket.len == PacketSize

    let processedPacket2 = SphinxPacket
      .deserialize(processedSP2.serializedSphinxPacket)
      .expect("Sphinx wrap error")

    let processedSP3 = processSphinxPacket(processedPacket2, privateKeys[2], tm).expect(
        "Sphinx processing error"
      )

    check processedSP3.status == Reply

    let msg = processReply(surb.key, surb.secret.get(), processedSP3.delta_prime).expect(
        "Reply processing failed"
      )

    check msg == message

  test "create surb empty public keys":
    let (message, _, _, delay, _, _) = createDummyData()
    check createSURB(@[], delay, @[], randomI()).isErr()

  test "surb sphinx process invalid mac":
    let (message, privateKeys, publicKeys, delay, hops, _) = createDummyData()

    let surb =
      createSURB(publicKeys, delay, hops, randomI()).expect("Create SURB error")

    let packetBytes = useSURB(surb, message).serialize()

    check packetBytes.len == PacketSize

    # Corrupt the MAC for testing
    var tamperedPacketBytes = packetBytes
    tamperedPacketBytes[0] = packetBytes[0] xor 0x01

    let tamperedPacket =
      SphinxPacket.deserialize(tamperedPacketBytes).expect("Sphinx wrap error")

    let processedSP1 = processSphinxPacket(tamperedPacket, privateKeys[0], tm).expect(
        "Sphinx processing error"
      )

    check processedSP1.status == InvalidMAC

  test "surb sphinx process duplicate tag":
    let (message, privateKeys, publicKeys, delay, hops, _) = createDummyData()

    let surb =
      createSURB(publicKeys, delay, hops, randomI()).expect("Create SURB error")

    let packetBytes = useSURB(surb, message).serialize()

    check packetBytes.len == PacketSize

    let packet = SphinxPacket.deserialize(packetBytes).expect("Sphinx wrap error")

    # Process the packet twice to test duplicate tag handling
    let processedSP1 =
      processSphinxPacket(packet, privateKeys[0], tm).expect("Sphinx processing error")

    check processedSP1.status == Intermediate

    let processedSP2 =
      processSphinxPacket(packet, privateKeys[0], tm).expect("Sphinx processing error")

    check processedSP2.status == Duplicate

  test "create and use surb message sizes":
    let messageSizes = @[32, 64, 128, 256, 512]
    for size in messageSizes:
      let (_, privateKeys, publicKeys, delay, hops, _) = createDummyData()
      var message = newSeq[byte](size)
      randomize()
      for i in 0 ..< size:
        message[i] = byte(rand(256))
      let paddedMessage = addPadding(message, MessageSize)

      let surb =
        createSURB(publicKeys, delay, hops, randomI()).expect("Create SURB error")

      let packetBytes = useSURB(surb, Message(paddedMessage)).serialize()

      check packetBytes.len == PacketSize

      let packet = SphinxPacket.deserialize(packetBytes).expect("Sphinx wrap error")

      let processedSP1 = processSphinxPacket(packet, privateKeys[0], tm).expect(
          "Sphinx processing error"
        )

      check:
        processedSP1.status == Intermediate
        processedSP1.serializedSphinxPacket.len == PacketSize

      let processedPacket1 = SphinxPacket
        .deserialize(processedSP1.serializedSphinxPacket)
        .expect("Sphinx wrap error")

      let processedSP2 = processSphinxPacket(processedPacket1, privateKeys[1], tm)
        .expect("Sphinx processing error")

      check:
        processedSP2.status == Intermediate
        processedSP2.serializedSphinxPacket.len == PacketSize

      let processedPacket2 = SphinxPacket
        .deserialize(processedSP2.serializedSphinxPacket)
        .expect("Sphinx wrap error")

      let processedSP3 = processSphinxPacket(processedPacket2, privateKeys[2], tm)
        .expect("Sphinx processing error")

      check processedSP3.status == Reply

      let msg = processReply(surb.key, surb.secret.get(), processedSP3.delta_prime)
        .expect("Reply processing failed")

      check paddedMessage == msg
