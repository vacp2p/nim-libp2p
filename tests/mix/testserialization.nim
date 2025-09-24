{.used.}

import results, unittest
import ../../libp2p/protocols/mix/serialization

# Define test cases
suite "serialization_tests":
  test "serialize_and_deserialize_header":
    let header = Header.init(
      newSeq[byte](AlphaSize), newSeq[byte](BetaSize), newSeq[byte](GammaSize)
    )
    let serialized = header.serialize()

    check serialized.len() == HeaderSize

  test "serialize_and_deserialize_message":
    let message = Message(newSeq[byte](MessageSize))
    let serialized = message.serialize()
    let deserialized =
      Message.deserialize(serialized).expect("Failed to deserialize message")

    check message == deserialized

  test "serialize_and_deserialize_hop":
    let hop = Hop.init(newSeq[byte](AddrSize))
    let serialized = hop.serialize()
    let deserialized = Hop.deserialize(serialized).expect("Failed to deserialize hop")

    check hop.get() == deserialized.get()

  test "serialize_and_deserialize_routing_info":
    let routingInfo = RoutingInfo.init(
      Hop.init(newSeq[byte](AddrSize)),
      newSeq[byte](DelaySize),
      newSeq[byte](GammaSize),
      newSeq[byte](((r * (t + 1)) - t) * k),
    )
    let serialized = routingInfo.serialize()
    let suffixLength = (t + 1) * k
    let suffix = newSeq[byte](suffixLength)
    let deserialized = RoutingInfo.deserialize(serialized & suffix).expect(
        "Failed to deserialize routing info"
      )
    let
      (hop, delay, gamma, beta) = getRoutingInfo(routingInfo)
      (dHop, dDelay, dGamma, dBeta) = getRoutingInfo(deserialized)

    check:
      hop.get() == dHop.get()
      delay == dDelay
      gamma == dGamma
      beta == dBeta[0 .. (((r * (t + 1)) - t) * k) - 1]

  test "serialize_and_deserialize_sphinx_packet":
    let
      header = Header.init(
        newSeq[byte](AlphaSize), newSeq[byte](BetaSize), newSeq[byte](GammaSize)
      )
      payload = newSeq[byte](PayloadSize)
      packet = SphinxPacket.init(header, payload)

    let serialized = packet.serialize()

    let deserializedSP =
      SphinxPacket.deserialize(serialized).expect("Failed to deserialize sphinx packet")

    check:
      header.Alpha == deserializedSP.Hdr.Alpha
      header.Beta == deserializedSP.Hdr.Beta
      header.Gamma == deserializedSP.Hdr.Gamma
      payload == deserializedSP.Payload
