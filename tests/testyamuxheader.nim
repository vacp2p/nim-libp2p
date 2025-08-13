{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ../libp2p/stream/bufferstream
import ./helpers

include ../libp2p/muxers/yamux/yamux

proc readBytes(bytes: array[12, byte]): Future[YamuxHeader] {.async.} =
  let bs = BufferStream.new()
  await bs.pushData(@bytes)
  defer:
    await bs.close()

  return await readHeader(bs)

suite "Yamux Header Tests":
  teardown:
    checkTrackers()

  suite "Yamux Header Encoding/Decoding":
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
      const streamId = 5
      let windowUpdateHeader =
        YamuxHeader.windowUpdate(streamId = streamId, delta = 1000, {Syn})
      let windowEncoded = windowUpdateHeader.encode()

      # [version == 0, msgType, flags_high, flags_low, 4x streamId_bytes, 4x delta_bytes]
      # delta == 1000 == 0x03E8, 0xE8 == 232
      const expected = [byte 0, 1, 0, 1, 0, 0, 0, streamId.byte, 0, 0, 3, 232]
      check:
        windowEncoded == expected

      let windowDecoded = await readBytes(windowEncoded)
      check:
        windowDecoded.version == 0
        windowDecoded.msgType == MsgType.WindowUpdate
        windowDecoded.flags == {Syn}
        windowDecoded.streamId == streamId
        windowDecoded.length == 1000

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
      let
        synHeader = YamuxHeader.data(streamId = streamId, length = length, {Syn})
        ackHeader = YamuxHeader.data(streamId = streamId, length = length, {Ack})
        finHeader = YamuxHeader.data(streamId = streamId, length = length, {Fin})
        rstHeader = YamuxHeader.data(streamId = streamId, length = length, {Rst})
      check:
        synHeader.encode()[2 .. 3] == [byte 0, 1]
        ackHeader.encode()[2 .. 3] == [byte 0, 2]
        finHeader.encode()[2 .. 3] == [byte 0, 4]
        rstHeader.encode()[2 .. 3] == [byte 0, 8]

      let synDecoded = await readBytes(synHeader.encode())
      let ackDecoded = await readBytes(ackHeader.encode())
      let finDecoded = await readBytes(finHeader.encode())
      let rstDecoded = await readBytes(rstHeader.encode())
      check:
        synDecoded.flags == {Syn}
        ackDecoded.flags == {Ack}
        finDecoded.flags == {Fin}
        rstDecoded.flags == {Rst}

      let synAckHeader =
        YamuxHeader.data(streamId = streamId, length = length, {Syn, Ack})
      let synFinHeader =
        YamuxHeader.data(streamId = streamId, length = length, {Syn, Fin})
      check:
        synAckHeader.encode()[2 .. 3] == [byte 0, 3]
        synFinHeader.encode()[2 .. 3] == [byte 0, 5]

      let synAckDecoded = await readBytes(synAckHeader.encode())
      let synFinDecoded = await readBytes(synFinHeader.encode())
      check:
        synAckDecoded.flags == {Syn, Ack}
        synFinDecoded.flags == {Syn, Fin}

    asyncTest "Boundary conditions":
      # Test maximum values
      let maxHeader = YamuxHeader.data(
        streamId = uint32.high, length = uint32.high, {Syn, Ack, Fin, Rst}
      )
      let maxEncoded = maxHeader.encode()

      const maxExpected = [byte 0, 0, 0, 15, 255, 255, 255, 255, 255, 255, 255, 255]
      check:
        maxEncoded == maxExpected

      let maxDecoded = await readBytes(maxEncoded)
      check:
        maxDecoded.version == 0
        maxDecoded.msgType == MsgType.Data
        maxDecoded.flags == {Syn, Ack, Fin, Rst}
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
