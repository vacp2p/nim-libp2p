# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/options
import ../../../multiaddress
import stew/objects

export multiaddress

type
  MsgType* = enum
    Connect = 100
    Sync = 300

  DcutrMsg* = object
    msgType*: MsgType
    addrs*: seq[MultiAddress]

proc encode*(msg: DcutrMsg): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, msg.msgType.uint)
  for addr in msg.addrs:
    result.write(2, addr)
  result.finish()

proc decode*(_: typedesc[DcutrMsg], buf: seq[byte]): DcutrMsg =
  var
    msgTypeOrd: uint32
    dcutrMsg: DcutrMsg
  var pb = initProtoBuffer(buf)
  var r1 = pb.getField(1, msgTypeOrd)
  let r2 = pb.getRepeatedField(2, dcutrMsg.addrs)
  if r1.isErr or r2.isErr or not checkedEnumAssign(dcutrMsg.msgType, msgTypeOrd):
    raise newException(DcutrError, "Received malformed message")
  return dcutrMsg



