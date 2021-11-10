import unittest2
import stew/byteutils
import ../libp2p/[signed_envelope]

suite "Signed envelope":
  test "Encode -> decode test":
    let
      rng = newRng()
      privKey = PrivateKey.random(rng[]).tryGet()
      envelope = Envelope.init(privKey, @[byte 12, 0], "payload".toBytes(), "domain").tryGet()
      buffer = envelope.encode().tryGet()
      decodedEnvelope = Envelope.decode(buffer, "domain").tryGet()
      wrongDomain = Envelope.decode(buffer, "wdomain")

    check:
      decodedEnvelope == envelope
      wrongDomain.error == EnvelopeInvalidSignature

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
