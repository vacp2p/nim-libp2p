{.used.}

import results, unittest
import ../../libp2p/protocols/mix/[serialization, utils]

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
      let multiAddrBytes =
        multiAddrToBytes(multiAddr).expect("multiaddress to bytes conversion failed")

      check multiAddrBytes.len == AddrSize

      let multiAddrString =
        bytesToMultiAddr(multiAddrBytes).expect("bytes to multiaddr conversion failed")

      check multiAddrString == multiAddr

  test "invalid_protocol":
    check multiAddrToBytes(
      "/ip4/0.0.0.0/abc/4242/p2p/16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC"
    ).isErr

  test "invalid_peerid_length":
    check multiAddrToBytes("/ip4/0.0.0.0/tcp/4242/p2p/16Uiu2HAmFk").isErr

  test "invalid_addr_length":
    let invalidBytes = newSeq[byte](AddrSize - 1)
    check bytesToMultiAddr(invalidBytes).isErr

  test "invalid_ip_address_format":
    check multiAddrToBytes(
      "/ip4/0.0.0/tcp/4242/p2p/16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC"
    ).isErr

  test "invalid_ip_address_part":
    check multiAddrToBytes(
      "/ip4/127.0.0.256/tcp/4242/p2p/16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC"
    ).isErr

  test "invalid_base58_encoding":
    check multiAddrToBytes(
      "/ip4/0.0.0.0/tcp/4242/p2p/16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgV!"
    ).isErr

  test "invalid_multiaddress_format":
    check multiAddrToBytes("/ip4/0.0.0.0/tcp/4242").isErr

  test "invalid_port_number":
    check multiAddrToBytes(
      "/ip4/0.0.0.0/tcp/65536/p2p/16Uiu2HAmFkwLVsVh6gGPmSm9R3X4scJ5thVdKfWYeJsKeVrbcgVC"
    ).isErr

  test "bytes_to_uint16_conversion":
    let res =
      bytesToUInt16([0x12'u8, 0x34'u8]).expect("bytes to uint16 conversion failed")
    check res == 0x1234'u16

  test "uint16_to_bytes_conversion":
    let value: uint16 = 0x1234
    let bytes = uint16ToBytes(value)
    check bytes == @[byte 0x12, 0x34]

  test "bytes_to_uint32_conversion":
    let res = bytesToUInt32([0x12'u8, 0x34'u8, 0x56'u8, 0x78'u8]).expect(
        "bytes to uint32 conversion failed"
      )
    check res == 0x12345678'u32

  test "uint32_to_bytes_conversion":
    let value: uint32 = 0x12345678
    let bytes = uint32ToBytes(value)
    check bytes == @[byte 0x12, 0x34, 0x56, 0x78]

  test "uint16_bytes_roundtrip":
    let original: uint16 = 0xABCD'u16
    let bytes = uint16ToBytes(original)
    let roundtrip = bytesToUInt16(bytes).expect("uint16 bytes roundtrip failed")
    check roundtrip == original

  test "uint32_bytes_roundtrip":
    let original: uint32 = 0x12345678'u32
    let bytes = uint32ToBytes(original)
    let roundtrip = bytesToUInt32(bytes).expect("uint32 bytes roundtrip failed")
    check roundtrip == original
