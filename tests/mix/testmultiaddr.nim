{.used.}

import results, unittest
import ../../libp2p/protocols/mix/[serialization, multiaddr]
import ../../libp2p/[peerid, multiaddress]

template maddr(ma: string): MultiAddress =
  MultiAddress.init(ma).tryGet()

proc maddrConversionShouldFail(ma: string, msg: string) =
  test msg:
    let peerId = PeerId.random().expect("could not generate peerId")
    let ma = MultiAddress.init(ma).expect("could not initialize multiaddr")
    check:
      multiAddrToBytes(peerId, ma).isErr

suite "Utils tests":
  test "multiaddress conversion":
    let multiAddrs = [
      "/ip4/0.0.0.0/tcp/4242", "/ip4/10.0.0.1/tcp/1234",
      "/ip4/192.168.1.1/udp/8080/quic-v1",
      "/ip4/10.0.0.1/tcp/1234/p2p/16Uiu2HAmDHw4mwBdEjxjJPhrt8Eq1kvDjXAuwkqCmhNiz363AFV2/p2p-circuit",
      "/ip4/10.0.0.1/udp/1234/quic-v1/p2p/16Uiu2HAmDHw4mwBdEjxjJPhrt8Eq1kvDjXAuwkqCmhNiz363AFV2/p2p-circuit",
    ]

    for multiAddr in multiAddrs:
      let
        ma = maddr(multiAddr)
        peerId = PeerId.random().expect("could not generate peerId")
        multiAddrBytes = multiAddrToBytes(peerId, ma).expect("conversion failed")

      check multiAddrBytes.len == AddrSize

      let (dPeerId, deserializedMa) =
        bytesToMultiAddr(multiAddrBytes).expect("conversion failed")

      check:
        deserializedMa == ma
        dPeerId == peerId

  maddrConversionShouldFail("/ip4/0.0.0.0/tcp/4242/quic-v1/", "invalid protocol")

  maddrConversionShouldFail("/ip4/0.0.0.0", "invalid multiaddress format")

  maddrConversionShouldFail(
    "/ip4/0.0.0.0/tcp/4242/p2p-circuit", "invalid multiaddress format circuit relay"
  )

  maddrConversionShouldFail(
    "/ip4/0.0.0.0/tcp/4242/p2p/QmcycySVeRSftFQGM392xCqDh6UUbhSU9ykNpxrFBPX3gJ/p2p-circuit",
    "invalid peerId in circuit relay addr",
  )

  test "invalid address length":
    let invalidBytes = newSeq[byte](AddrSize - 1)
    check:
      bytesToMultiAddr(invalidBytes).isErr
