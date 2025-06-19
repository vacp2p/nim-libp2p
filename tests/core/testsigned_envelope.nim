{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import unittest2
import stew/byteutils
import ../libp2p/[signed_envelope]

suite "Signed envelope":
  test "Encode -> decode -> encode -> decode test":
    let
      rng = newRng()
      privKey = PrivateKey.random(rng[]).tryGet()
      envelope =
        Envelope.init(privKey, @[byte 12, 0], "payload".toBytes(), "domain").tryGet()
      buffer = envelope.encode().tryGet()
      decodedEnvelope = Envelope.decode(buffer, "domain").tryGet()
      wrongDomain = Envelope.decode(buffer, "wdomain")

      reencodedEnvelope = decodedEnvelope.encode().tryGet()
      redecodedEnvelope = Envelope.decode(reencodedEnvelope, "domain").tryGet()

    check:
      decodedEnvelope == envelope
      wrongDomain.error == EnvelopeInvalidSignature

      reencodedEnvelope == buffer
      redecodedEnvelope == envelope

  test "Interop decode test":
    # from https://github.com/libp2p/go-libp2p-core/blob/b18a4c9c5629870bde2cd85ab3b87a507600d411/record/envelope_test.go#L68
    let inputData = "0a24080112206f1581709bb7b1ef030d210db18e3b0ba1c776fba65d8cdaad05415142d189f812102f6c69627032702f74657374646174611a0c68656c6c6f20776f726c64212a401178673b51dfa842aad17e465e25d646ad16628916b964c3fb10c711fee87872bdd4e4646f58c277cdff09704913d8be1aec6322de8d3d0bb852120374aece08".hexToSeqByte()
    let decodedEnvelope = Envelope.decode(inputData, "libp2p-testing").tryGet()
    check:
      decodedEnvelope.payloadType == "/libp2p/testdata".toBytes()
      decodedEnvelope.payload == "hello world!".toBytes()

  test "Signature validation":
    # same as above, but payload altered
    let inputData = "0a24080112206f1581709bb7b1ef030d210db18e3b0ba1c776fba65d8cdaad05415142d189f812102f6c69627032702f74657374646174611a0c00006c6c6f20776f726c64212a401178673b51dfa842aad17e465e25d646ad16628916b964c3fb10c711fee87872bdd4e4646f58c277cdff09704913d8be1aec6322de8d3d0bb852120374aece08".hexToSeqByte()
    check Envelope.decode(inputData, "libp2p-testing").error == EnvelopeInvalidSignature

# needs to be exported to work
type
  DummyPayload* = object
    awesome: byte

  SignedDummy = SignedPayload[DummyPayload]

proc decode*(
    T: typedesc[DummyPayload], buffer: seq[byte]
): Result[DummyPayload, cstring] =
  ok(DummyPayload(awesome: buffer[0]))

proc encode*(pd: DummyPayload): seq[byte] =
  @[pd.awesome]

proc checkValid*(pd: SignedDummy): Result[void, EnvelopeError] =
  if pd.data.awesome == 12.byte:
    ok()
  else:
    err(EnvelopeInvalidSignature)

proc payloadDomain*(T: typedesc[DummyPayload]): string =
  "dummy"

proc payloadType*(T: typedesc[DummyPayload]): seq[byte] =
  @[(byte) 0x00, (byte) 0x00]

suite "Signed payload":
  test "Simple encode -> decode":
    let
      rng = newRng()
      privKey = PrivateKey.random(rng[]).tryGet()

      dummyPayload = DummyPayload(awesome: 12.byte)
      signed = SignedDummy.init(privKey, dummyPayload).tryGet()
      encoded = signed.encode().tryGet()
      decoded = SignedDummy.decode(encoded).tryGet()

    check:
      dummyPayload.awesome == decoded.data.awesome
      decoded.envelope.publicKey == privKey.getPublicKey().tryGet()

  test "Invalid payload":
    let
      rng = newRng()
      privKey = PrivateKey.random(rng[]).tryGet()

      dummyPayload = DummyPayload(awesome: 30.byte)
      signed = SignedDummy.init(privKey, dummyPayload).tryGet()
      encoded = signed.encode().tryGet()
    check SignedDummy.decode(encoded).error == EnvelopeInvalidSignature

  test "Invalid payload type":
    let
      rng = newRng()
      privKey = PrivateKey.random(rng[]).tryGet()

      dummyPayload = DummyPayload(awesome: 30.byte)
      signed = Envelope
        .init(privKey, @[55.byte], dummyPayload.encode(), DummyPayload.payloadDomain)
        .tryGet()
      encoded = signed.encode().tryGet()
    check SignedDummy.decode(encoded).error == EnvelopeWrongType
