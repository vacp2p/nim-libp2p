{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ../libp2p/stream/[bufferstream, lpstream]
import ./helpers

include ../libp2p/muxers/yamux/yamux

proc readBytes(bytes: array[12, byte]): Future[YamuxHeader] {.async.} =
  let bs = BufferStream.new()
  defer:
    await bs.close()

  await bs.pushData(@bytes)

  return await readHeader(bs)

suite "Yamux Header Tests":
  teardown:
    checkTrackers()

  asyncTest "Data header":
    const
      streamId = 1
      length = 100
      flags = {Syn}
    let header = YamuxHeader.data(streamId = streamId, length = length, flags)
    let dataEncoded = header.encode()

    # [version == 0, msgType, flags_high, flags_low, 4x streamId_bytes, 4x length_bytes]
    const expected = [byte 0, 0, 0, 1, 0, 0, 0, streamId.byte, 0, 0, 0, length.byte]
    check:
      dataEncoded == expected

    let headerDecoded = await readBytes(dataEncoded)
    check:
      headerDecoded.version == 0
      headerDecoded.msgType == MsgType.Data
      headerDecoded.flags == flags
      headerDecoded.streamId == streamId
      headerDecoded.length == length

  asyncTest "Window update":
    const
      streamId = 5
      delta = 1000
      flags = {Syn}
    let windowUpdateHeader =
      YamuxHeader.windowUpdate(streamId = streamId, delta = delta, flags)
    let windowEncoded = windowUpdateHeader.encode()

    # [version == 0, msgType, flags_high, flags_low, 4x streamId_bytes, 4x delta_bytes]
    # delta == 1000 == 0x03E8
    const expected = [byte 0, 1, 0, 1, 0, 0, 0, streamId.byte, 0, 0, 0x03, 0xE8]
    check:
      windowEncoded == expected

    let windowDecoded = await readBytes(windowEncoded)
    check:
      windowDecoded.version == 0
      windowDecoded.msgType == MsgType.WindowUpdate
      windowDecoded.flags == flags
      windowDecoded.streamId == streamId
      windowDecoded.length == delta

  asyncTest "Ping":
    let pingHeader = YamuxHeader.ping(MsgFlags.Syn, 0x12345678'u32)
    let pingEncoded = pingHeader.encode()

    # [version == 0, msgType, flags_high, flags_low, 4x streamId_bytes, 4x value_bytes]
    const expected = [byte 0, 2, 0, 1, 0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78]
    check:
      pingEncoded == expected

    let pingDecoded = await readBytes(pingEncoded)
    check:
      pingDecoded.version == 0
      pingDecoded.msgType == MsgType.Ping
      pingDecoded.flags == {Syn}
      pingDecoded.streamId == 0
      pingDecoded.length == 0x12345678'u32

  asyncTest "Go away":
    let goAwayHeader = YamuxHeader.goAway(GoAwayStatus.ProtocolError)
    let goAwayEncoded = goAwayHeader.encode()

    # [version == 0, msgType, flags_high, flags_low, 4x streamId_bytes, 4x error_bytes]
    const expected = [byte 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    check:
      goAwayEncoded == expected

    let goAwayDecoded = await readBytes(goAwayEncoded)
    check:
      goAwayDecoded.version == 0
      goAwayDecoded.msgType == MsgType.GoAway
      goAwayDecoded.flags == {}
      goAwayDecoded.streamId == 0
      goAwayDecoded.length == 1'u32

  asyncTest "Error codes":
    let encodedNormal = YamuxHeader.goAway(GoAwayStatus.NormalTermination).encode()
    let encodedProtocol = YamuxHeader.goAway(GoAwayStatus.ProtocolError).encode()
    let encodedInternal = YamuxHeader.goAway(GoAwayStatus.InternalError).encode()
    check:
      encodedNormal[11] == 0
      encodedProtocol[11] == 1
      encodedInternal[11] == 2

    let decodedNormal = await readBytes(encodedNormal)
    let decodedProtocol = await readBytes(encodedProtocol)
    let decodedInternal = await readBytes(encodedInternal)
    check:
      decodedNormal.msgType == MsgType.GoAway
      decodedNormal.length == 0'u32
      decodedProtocol.msgType == MsgType.GoAway
      decodedProtocol.length == 1'u32
      decodedInternal.msgType == MsgType.GoAway
      decodedInternal.length == 2'u32

  asyncTest "Flags":
    const
      streamId = 1
      length = 100
    let cases: seq[(set[MsgFlags], uint8)] =
      @[
        ({Syn}, 1'u8),
        ({Ack}, 2'u8),
        ({Syn, Ack}, 3'u8),
        ({Fin}, 4'u8),
        ({Syn, Fin}, 5'u8),
        ({Ack, Fin}, 6'u8),
        ({Syn, Ack, Fin}, 7'u8),
        ({Rst}, 8'u8),
        ({Syn, Rst}, 9'u8),
        ({Ack, Rst}, 10'u8),
        ({Syn, Ack, Rst}, 11'u8),
        ({Fin, Rst}, 12'u8),
        ({Syn, Fin, Rst}, 13'u8),
        ({Ack, Fin, Rst}, 14'u8),
        ({Syn, Ack, Fin, Rst}, 15'u8),
      ]

    for (flags, low) in cases:
      let header = YamuxHeader.data(streamId = streamId, length = length, flags)
      let encoded = header.encode()
      check encoded[2 .. 3] == [byte 0, low]

      let decoded = await readBytes(encoded)
      check decoded.flags == flags

  asyncTest "Boundary conditions":
    # Test maximum values
    const maxFlags = {Syn, Ack, Fin, Rst}
    let maxHeader =
      YamuxHeader.data(streamId = uint32.high, length = uint32.high, maxFlags)
    let maxEncoded = maxHeader.encode()

    const maxExpected = [byte 0, 0, 0, 15, 255, 255, 255, 255, 255, 255, 255, 255]
    check:
      maxEncoded == maxExpected

    let maxDecoded = await readBytes(maxEncoded)
    check:
      maxDecoded.version == 0
      maxDecoded.msgType == MsgType.Data
      maxDecoded.flags == maxFlags
      maxDecoded.streamId == uint32.high
      maxDecoded.length == uint32.high

    # Test minimum values
    let minHeader = YamuxHeader.data(streamId = 0, length = 0, {})
    let minEncoded = minHeader.encode()

    const minExpected = [byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    check:
      minEncoded == minExpected

    let minDecoded = await readBytes(minEncoded)
    check:
      minDecoded.version == 0
      minDecoded.msgType == MsgType.Data
      minDecoded.flags == {}
      minDecoded.streamId == 0
      minDecoded.length == 0'u32

  asyncTest "Incomplete header should raise LPStreamIncompleteError":
    let buff = BufferStream.new()

    let valid = YamuxHeader.data(streamId = 7, length = 0, {}).encode()
    # Supply only first 10 bytes (<12)
    let partial: seq[byte] = @valid[0 .. 9]
    await buff.pushData(partial)

    # Start the read first so close() can propagate EOF to it
    let headerFut = readHeader(buff)
    await buff.close()

    expect LPStreamIncompleteError:
      discard await headerFut

  asyncTest "Non-zero version byte is preserved":
    let valid = YamuxHeader.data(streamId = 1, length = 100, {Syn}).encode()
    var mutated = valid
    mutated[0] = 1'u8

    let decoded = await readBytes(mutated)
    check:
      decoded.version == 1

  asyncTest "Invalid msgType should raise YamuxError":
    let valid = YamuxHeader.data(streamId = 1, length = 0, {}).encode()
    var mutated = valid
    mutated[1] = 0xFF'u8

    expect YamuxError:
      discard await readBytes(mutated)

  asyncTest "Invalid flags should raise YamuxError":
    let valid = YamuxHeader.data(streamId = 1, length = 0, {}).encode()
    var mutated = valid
    # Set flags to 16 which is outside the allowed 0..15 range
    mutated[2] = 0'u8
    mutated[3] = 16'u8

    expect YamuxError:
      discard await readBytes(mutated)

  asyncTest "Invalid flags (high byte non-zero) should raise YamuxError":
    let valid = YamuxHeader.data(streamId = 1, length = 0, {}).encode()
    var mutated = valid
    # Set high flags byte to 1, which is outside the allowed 0..15 range
    mutated[2] = 1'u8
    mutated[3] = 0'u8

    expect YamuxError:
      discard await readBytes(mutated)

  asyncTest "Partial push (6+6 bytes) completes without closing":
    const
      streamId = 9
      length = 42
      flags = {Syn}

    # Prepare a valid header
    let header = YamuxHeader.data(streamId = streamId, length = length, flags)
    let bytes = header.encode()

    let buff = BufferStream.new()
    defer:
      await buff.close()

    # Push first half (6 bytes)
    let first: seq[byte] = @bytes[0 .. 5]
    await buff.pushData(first)

    # Start read and then push the remaining bytes
    let headerFut = readHeader(buff)
    let second: seq[byte] = @bytes[6 .. 11]
    await buff.pushData(second)

    let decoded = await headerFut
    check:
      decoded.version == 0
      decoded.msgType == MsgType.Data
      decoded.flags == flags
      decoded.streamId == streamId
      decoded.length == length

  asyncTest "Two headers back-to-back decode sequentially":
    let h1 = YamuxHeader.data(streamId = 2, length = 10, {Ack})
    let h2 = YamuxHeader.ping(MsgFlags.Syn, 0xABCDEF01'u32)
    let b1 = h1.encode()
    let b2 = h2.encode()

    let buff = BufferStream.new()
    defer:
      await buff.close()

    await buff.pushData(@b1 & @b2)

    let d1 = await readHeader(buff)
    let d2 = await readHeader(buff)

    check:
      d1.msgType == MsgType.Data
      d1.streamId == 2
      d1.length == 10
      d1.flags == {Ack}
      d2.msgType == MsgType.Ping
      d2.streamId == 0
      d2.length == 0xABCDEF01'u32
      d2.flags == {Syn}

  asyncTest "StreamId 0x01020304 encodes big-endian":
    const streamId = 0x01020304'u32
    let header = YamuxHeader.data(streamId = streamId, length = 0, {})
    let enc = header.encode()
    check enc[4 .. 7] == [byte 1, 2, 3, 4]

    let dec = await readBytes(enc)
    check dec.streamId == streamId

  asyncTest "GoAway unknown status code is preserved":
    let valid = YamuxHeader.goAway(GoAwayStatus.NormalTermination).encode()
    var mutated = valid
    # Set the GoAway code (last byte) to 255, which is not a known GoAwayStatus
    mutated[11] = 255'u8

    let decoded = await readBytes(mutated)
    check:
      decoded.msgType == MsgType.GoAway
      decoded.length == 255'u32
