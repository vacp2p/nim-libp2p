{.used.}

import results, unittest
import ../../libp2p/protocols/mix/[serialization, multiaddr]
import ../../libp2p/multiaddress

template maddr(ma: string): MultiAddress =
  MultiAddress.init(ma).tryGet()

template maddrConversionShouldFail(ma: string, msg: string) =
  test msg:
    echo MultiAddress
    .init(ma)
    .expect("could not initialize multiaddr")
    .multiAddrToBytes()
    .error()
    check:
      MultiAddress
      .init(ma)
      .expect("could not initialize multiaddr")
      .multiAddrToBytes().isErr

suite "Utils tests":
  test "multi_addr_conversion":
    let multiAddrs = [
      "/ip4/0.0.0.0/tcp/4242/p2p/16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC",
      "/ip4/10.0.0.1/tcp/1234/p2p/16Uiu2HAmDHw4mwBdEjxjJPhrt8Eq1kvDjXAuwkqCmhNiz363AFV2",
      "/ip4/192.168.1.1/udp/8080/quic-v1/p2p/16Uiu2HAm6WNzw8AssyPscYYi8x1bY5wXyQrGTShRH75bh5dPCjBQ",
      "/ip4/10.0.0.1/tcp/1234/p2p/16Uiu2HAmDHw4mwBdEjxjJPhrt8Eq1kvDjXAuwkqCmhNiz363AFV2/p2p-circuit/p2p/16Uiu2HAm6WNzw8AssyPscYYi8x1bY5wXyQrGTShRH75bh5dPCjBQ",
      "/ip4/10.0.0.1/udp/1234/quic-v1/p2p/16Uiu2HAmDHw4mwBdEjxjJPhrt8Eq1kvDjXAuwkqCmhNiz363AFV2/p2p-circuit/p2p/16Uiu2HAm6WNzw8AssyPscYYi8x1bY5wXyQrGTShRH75bh5dPCjBQ",
    ]

    for multiAddr in multiAddrs:
      let ma = maddr(multiAddr)
      let multiAddrBytes = ma.multiAddrToBytes().expect("conversion failed")
      check multiAddrBytes.len == AddrSize
      let deserializedMa = bytesToMultiAddr(multiAddrBytes).expect("conversion failed")
      check deserializedMa == ma

  maddrConversionShouldFail(
    "/ip4/0.0.0.0/tcp/4242/quic-v1/p2p/16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC",
    "invalid_protocol",
  )

  maddrConversionShouldFail(
    "/ip4/0.0.0.0/tcp/4242/p2p/QmcycySVeRSftFQGM392xCqDh6UUbhSU9ykNpxrFBPX3gJ",
    "invalid_peerid_length",
  )

  maddrConversionShouldFail("/ip4/0.0.0.0/tcp/4242", "invalid_multiaddress_format")

  maddrConversionShouldFail(
    "/ip4/0.0.0.0/tcp/4242/p2p-circuit", "invalid_multiaddress_format_circuit_relay"
  )

  test "invalid_addr_length":
    let invalidBytes = newSeq[byte](AddrSize - 1)
    check:
      bytesToMultiAddr(invalidBytes).isErr
