# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../libp2p/vbuffer
import ../tools/unittest

suite "VBuffer":
  test "truncated sequence preserves the read position":
    var buffer = initVBuffer(@[3'u8, 1, 2])
    var value: seq[byte]
    check buffer.peekSeq(value) == -1
    check buffer.offset == 0
    check value.len == 0
    check buffer.readSeq(value) == -1
    check buffer.offset == 0
    buffer.buffer.add(3)
    check buffer.readSeq(value) == 4
    check value == @[1'u8, 2, 3]
    check buffer.isEmpty

  test "complete and empty sequences advance by their encoded lengths":
    var buffer = initVBuffer(@[0'u8, 2, 1, 2])
    var value: seq[byte]
    check buffer.readSeq(value) == 1
    check value.len == 0
    check buffer.peekSeq(value) == 3
    check value == @[1'u8, 2]
    check buffer.offset == 1
    check buffer.readSeq(value) == 3
    check buffer.isEmpty
