# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import stew/[endians2], results
import ../../../interop/gossipsub/src/[interop_partial_message]
import ../../tools/[unittest]

suite "GossipSub Interop - InteropPartialMessage":
  test "bitmap tracks present parts":
    let pm = newInteropPartialMessage(1)
    check:
      pm.bitmap == 0
      pm.partsPresent() == 0
      not pm.isComplete()

    pm.fillParts(0b00000101) # parts 0 and 2
    check:
      pm.bitmap == 0b00000101
      pm.partsPresent() == 2
      not pm.isComplete()

  test "isComplete when all 8 parts present":
    let pm = newInteropPartialMessage(1)
    pm.fillParts(0xFF)
    check:
      pm.bitmap == 0xFF
      pm.partsPresent() == 8
      pm.isComplete()

  test "fillParts generates deterministic data":
    let pm = newInteropPartialMessage(100)
    pm.fillParts(0b00000001) # part 0 only

    check pm.parts[0].len == 1024

    # Part 0, slot 0: start = 100
    let slot0 = fromBytesBE(uint64, pm.parts[0].toOpenArray(0, 7))
    check slot0 == 100'u64

    # Part 0, slot 1: start + 1 = 101
    let slot1 = fromBytesBE(uint64, pm.parts[0].toOpenArray(8, 15))
    check slot1 == 101'u64

    # Part 0, last slot (127): start + 127 = 227
    let slot127 = fromBytesBE(uint64, pm.parts[0].toOpenArray(127 * 8, 127 * 8 + 7))
    check slot127 == 227'u64

  test "fillParts offset per part":
    let pm = newInteropPartialMessage(0)
    pm.fillParts(0b00000011) # parts 0 and 1

    # Part 0 starts at counter = 0
    let p0s0 = fromBytesBE(uint64, pm.parts[0].toOpenArray(0, 7))
    check p0s0 == 0'u64

    # Part 1 starts at counter = 0 + 1*128 = 128
    let p1s0 = fromBytesBE(uint64, pm.parts[1].toOpenArray(0, 7))
    check p1s0 == 128'u64

  test "fillParts last slot value":
    let pm = newInteropPartialMessage(0)
    pm.fillParts(0b10000000) # part 7 only

    # Part 7 starts at counter = 0 + 7*128 = 896
    let p7s0 = fromBytesBE(uint64, pm.parts[7].toOpenArray(0, 7))
    check p7s0 == 896'u64

    # Part 7, last slot: 896 + 127 = 1023
    let p7last = fromBytesBE(uint64, pm.parts[7].toOpenArray(127 * 8, 127 * 8 + 7))
    check p7last == 1023'u64

suite "GossipSub Interop - Wire Format":
  test "materializeParts encodes parts peer doesn't have":
    let pm = newInteropPartialMessage(42)
    pm.fillParts(0b00000111) # parts 0, 1, 2

    # Peer has part 0 (bitmap = 0b00000001), needs parts 1 and 2
    let res = pm.materializeParts(@[0b00000001'u8])
    check res.isOk()

    let data = res.get()
    # Format: [bitmap: 1][part1: 1024][part2: 1024][groupId: 8]
    check data.len == 1 + 2 * 1024 + 8

    # Response bitmap should be 0b00000110 (parts 1 and 2)
    check data[0] == 0b00000110'u8

    # Group ID at end
    let gid = fromBytesBE(uint64, data[data.len - 8 ..< data.len])
    check gid == 42'u64

  test "materializeParts returns empty when peer has all":
    let pm = newInteropPartialMessage(42)
    pm.fillParts(0b00000011) # parts 0, 1

    # Peer has both parts
    let res = pm.materializeParts(@[0b00000011'u8])
    check res.isOk()
    check res.get().len == 0

  test "materializeParts skips parts we don't have":
    let pm = newInteropPartialMessage(42)
    pm.fillParts(0b00000001) # only part 0

    # Peer has nothing
    let res = pm.materializeParts(@[0b00000000'u8])
    check res.isOk()

    let data = res.get()
    check data.len == 1 + 1024 + 8
    check data[0] == 0b00000001'u8

  test "extend decodes wire format":
    let sender = newInteropPartialMessage(42)
    sender.fillParts(0b00000011) # parts 0, 1

    # Encode parts for a peer with nothing
    let encoded = sender.materializeParts(@[0b00000000'u8]).get()

    # Receiver decodes
    let receiver = newInteropPartialMessage(42)
    let res = receiver.extend(encoded)
    check res.isOk()
    check receiver.bitmap == 0b00000011
    check receiver.parts[0] == sender.parts[0]
    check receiver.parts[1] == sender.parts[1]

  test "extend ignores parts already present":
    let sender = newInteropPartialMessage(42)
    sender.fillParts(0b00000011)

    let receiver = newInteropPartialMessage(42)
    receiver.fillParts(0b00000001) # already has part 0

    let encoded = sender.materializeParts(@[0b00000001'u8]).get() # sends only part 1
    let res = receiver.extend(encoded)
    check res.isOk()
    check receiver.bitmap == 0b00000011

  test "extend correctly reads part after a duplicate — offset must advance past duplicate":
    # Regression: sender encodes parts 0 and 2; receiver already has part 0.
    # The wire stream is [part0_bytes][part2_bytes].
    # When skipping part 0 (already held), offset must advance past its 1024 bytes
    # so that part 2 is read from the right position, not from part 0's bytes.
    let sender = newInteropPartialMessage(42)
    sender.fillParts(0b00000101) # parts 0 and 2

    # Encode for a peer that has nothing (so both parts appear in the stream contiguously)
    let encoded = sender.materializeParts(@[0b00000000'u8]).get()
    check encoded.len == 1 + 2 * 1024 + 8

    let receiver = newInteropPartialMessage(42)
    receiver.fillParts(0b00000001) # already has part 0

    let res = receiver.extend(encoded)
    check res.isOk()
    check receiver.bitmap == 0b00000101
    # part 2 must contain the correct bytes, not part 0's bytes
    check receiver.parts[2] == sender.parts[2]

  test "extend rejects wrong group ID":
    let sender = newInteropPartialMessage(42)
    sender.fillParts(0b00000001)

    let encoded = sender.materializeParts(@[0b00000000'u8]).get()

    let receiver = newInteropPartialMessage(99) # different group ID
    let res = receiver.extend(encoded)
    check res.isErr()

  test "extend rejects data too short":
    let receiver = newInteropPartialMessage(42)
    let res = receiver.extend(@[0'u8]) # way too short
    check res.isErr()

  test "extend accumulates across multiple calls":
    let pm1 = newInteropPartialMessage(42)
    pm1.fillParts(0b00000001) # part 0

    let pm2 = newInteropPartialMessage(42)
    pm2.fillParts(0b00000010) # part 1

    let receiver = newInteropPartialMessage(42)

    let enc1 = pm1.materializeParts(@[0'u8]).get()
    check receiver.extend(enc1).isOk()
    check receiver.bitmap == 0b00000001

    let enc2 = pm2.materializeParts(@[0b00000001'u8]).get()
    check receiver.extend(enc2).isOk()
    check receiver.bitmap == 0b00000011

suite "GossipSub Interop - Bitmap Metadata":
  test "partsMetadata returns 1-byte bitmap":
    let pm = newInteropPartialMessage(0)
    check pm.partsMetadata() == @[0'u8]

    pm.fillParts(0b10101010)
    check pm.partsMetadata() == @[0b10101010'u8]

  test "interopUnionPartsMetadata performs OR":
    let res = interopUnionPartsMetadata(@[0b00001111'u8], @[0b11110000'u8])
    check res.isOk()
    check res.get() == @[0b11111111'u8]

  test "interopUnionPartsMetadata rejects wrong length":
    check interopUnionPartsMetadata(@[1'u8, 2'u8], @[3'u8]).isErr()
    check interopUnionPartsMetadata(@[1'u8], @[]).isErr()
