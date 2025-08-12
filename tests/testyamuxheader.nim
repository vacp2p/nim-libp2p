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

suite "Yamux":
  teardown:
    checkTrackers()

  suite "Yamux Header Tests":
    test "Basic header construction and version":
      let dataHeader = YamuxHeader.data(streamId = 1, length = 100, {Syn})

      check:
        dataHeader.version == YamuxVersion
        dataHeader.msgType == MsgType.Data
        dataHeader.flags == {Syn}
        dataHeader.streamId == 1
        dataHeader.length == 100

    test "Header encoding - basic data header":
      const
        streamId = 1
        length = 100
      let header = YamuxHeader.data(streamId = streamId, length = length, {Syn})
      let encoded = header.encode()

      # Check the encoded structure [version, msgType, flags_high, flags_low, streamId_bytes, length_bytes]
      check:
        encoded[0] == 0 # version always 0
        encoded[1] == 0 # msgType 0 (Data)
        encoded[2] == 0 # flags high byte
        encoded[3] == 1 # flags low byte (Syn)
        encoded[4] == 0 # streamId high bytes
        encoded[5] == 0
        encoded[6] == 0
        encoded[7] == streamId
        encoded[8] == 0 # length high bytes
        encoded[9] == 0
        encoded[10] == 0
        encoded[11] == length

    test "Header encoding - flags":
      const
        streamId = 1
        length = 100
      let
        synHeader = YamuxHeader.data(streamId = streamId, length = length, {Syn})
        ackHeader = YamuxHeader.data(streamId = streamId, length = length, {Ack})
        finHeader = YamuxHeader.data(streamId = streamId, length = length, {Fin})
        rstHeader = YamuxHeader.data(streamId = streamId, length = length, {Rst})

      # flags are in bytes 2-3 as big-endian uint16
      check:
        synHeader.encode()[2] == 0
        synHeader.encode()[3] == 1

        ackHeader.encode()[2] == 0
        ackHeader.encode()[3] == 2

        finHeader.encode()[2] == 0
        finHeader.encode()[3] == 4

        rstHeader.encode()[2] == 0
        rstHeader.encode()[3] == 8

      let synAckHeader =
        YamuxHeader.data(streamId = streamId, length = length, {Syn, Ack})
      let synFinHeader =
        YamuxHeader.data(streamId = streamId, length = length, {Syn, Fin})

      check:
        synAckHeader.encode()[2] == 0
        synAckHeader.encode()[3] == 3 # Syn + Ack = 1 + 2 = 3

        synFinHeader.encode()[2] == 0
        synFinHeader.encode()[3] == 5 # Syn + Fin = 1 + 4 = 5

    test "Header encoding - window update":
      const streamId = 5
      let windowUpdateHeader =
        YamuxHeader.windowUpdate(streamId = streamId, delta = 1000, {Syn})
      let windowEncoded = windowUpdateHeader.encode()

      check:
        windowEncoded[0] == 0 # version
        windowEncoded[1] == 1 # msgType
        windowEncoded[2] == 0
        windowEncoded[3] == 1 # flags (Syn)
        windowEncoded[4] == 0
        windowEncoded[5] == 0
        windowEncoded[6] == 0
        windowEncoded[7] == streamId
        # delta = 1000 = 0x03E8, check length field
        windowEncoded[8] == 0
        windowEncoded[9] == 0
        windowEncoded[10] == 3
        windowEncoded[11] == 232 # 0xE8 = 232

    test "Header encoding - ping":
      let pingHeader = YamuxHeader.ping(MsgFlags.Syn, 0x12345678'u32)
      let pingEncoded = pingHeader.encode()

      check:
        pingEncoded[0] == 0 # version
        pingEncoded[1] == 2 # msgType
        pingEncoded[2] == 0
        pingEncoded[3] == 1 # flag (Syn)
        pingEncoded[4] == 0 # streamId should be 0 for ping
        pingEncoded[5] == 0
        pingEncoded[6] == 0
        pingEncoded[7] == 0
        # ping data = 0x12345678
        pingEncoded[8] == 0x12
        pingEncoded[9] == 0x34
        pingEncoded[10] == 0x56
        pingEncoded[11] == 0x78

    test "Header encoding - go away":
      let goAwayHeader = YamuxHeader.goAway(GoAwayStatus.ProtocolError)
      let goAwayEncoded = goAwayHeader.encode()

      check:
        goAwayEncoded[0] == 0 # version
        goAwayEncoded[1] == 3 # msgType
        goAwayEncoded[2] == 0 # flags should be empty
        goAwayEncoded[3] == 0
        goAwayEncoded[4] == 0 # streamId should be 0 for goaway
        goAwayEncoded[5] == 0
        goAwayEncoded[6] == 0
        goAwayEncoded[7] == 0
        goAwayEncoded[8] == 0 # status
        goAwayEncoded[9] == 0
        goAwayEncoded[10] == 0
        goAwayEncoded[11] == 1 # ProtocolError = 1
