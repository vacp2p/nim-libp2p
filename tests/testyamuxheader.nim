{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
from strutils import contains
import stew/endians2
import
  ../libp2p/
    [stream/connection, stream/bridgestream, stream/bufferstream, muxers/yamux/yamux]
import ./helpers

include ../libp2p/muxers/yamux/yamux

suite "Yamux Header Tests":
  teardown:
    checkTrackers()

  test "Header encoding - basic data header":
    const
      streamId = 1
      length = 100
    let header = YamuxHeader.data(streamId = streamId, length = length, {Syn})
    let dataEncoded = header.encode()

    # [version == 0, msgType, flags_high, flags_low, 4x streamId_bytes, 4x length_bytes]
    const expected = [byte 0, 0, 0, 1, 0, 0, 0, streamId.byte, 0, 0, 0, length.byte]

    check:
      dataEncoded == expected

  test "Header encoding - window update":
    const streamId = 5
    let windowUpdateHeader =
      YamuxHeader.windowUpdate(streamId = streamId, delta = 1000, {Syn})
    let windowEncoded = windowUpdateHeader.encode()

    # [version == 0, msgType, flags_high, flags_low, 4x streamId_bytes, 4x delta_bytes]
    # delta == 1000 == 0x03E8, 0xE8 == 232
    const expected = [byte 0, 1, 0, 1, 0, 0, 0, streamId.byte, 0, 0, 3, 232]

    check:
      windowEncoded == expected

  test "Header encoding - ping":
    let pingHeader = YamuxHeader.ping(MsgFlags.Syn, 0x12345678'u32)
    let pingEncoded = pingHeader.encode()

    # [version == 0, msgType, flags_high, flags_low, 4x streamId_bytes, 4x value_bytes]
    const expected = [byte 0, 2, 0, 1, 0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78]

    check:
      pingEncoded == expected

  test "Header encoding - go away":
    let goAwayHeader = YamuxHeader.goAway(GoAwayStatus.ProtocolError)
    let goAwayEncoded = goAwayHeader.encode()

    # [version == 0, msgType, flags_high, flags_low, 4x streamId_bytes, 4x error_bytes]
    const expected = [byte 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

    check:
      goAwayEncoded == expected

  test "Header encoding - error codes":
    check:
      YamuxHeader.goAway(GoAwayStatus.NormalTermination).encode()[11] == 0
      YamuxHeader.goAway(GoAwayStatus.ProtocolError).encode()[11] == 1
      YamuxHeader.goAway(GoAwayStatus.InternalError).encode()[11] == 2

  test "Header encoding - flags":
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

    let synAckHeader =
      YamuxHeader.data(streamId = streamId, length = length, {Syn, Ack})
    let synFinHeader =
      YamuxHeader.data(streamId = streamId, length = length, {Syn, Fin})

    check:
      synAckHeader.encode()[2 .. 3] == [byte 0, 3]
      synFinHeader.encode()[2 .. 3] == [byte 0, 5]

  test "Header encoding - boundary conditions":
    # Test maximum values
    let maxHeader = YamuxHeader.data(
      streamId = uint32.high, length = uint32.high, {Syn, Ack, Fin, Rst}
    )
    let maxEncoded = maxHeader.encode()

    const maxExpected = [byte 0, 0, 0, 15, 255, 255, 255, 255, 255, 255, 255, 255]
    check:
      maxEncoded == maxExpected

    # Test minimum values
    let minHeader = YamuxHeader.data(streamId = 0, length = 0, {})
    let minEncoded = minHeader.encode()

    const minExpected = [byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    check:
      minEncoded == minExpected
