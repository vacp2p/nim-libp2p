# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import stew/byteutils

proc ma1StB(s: string, vb: var VBuffer): bool =
  vb.writeSeq(s)
  return true

proc ma1BtS(vb: var VBuffer, s: var string): bool =
  vb.readSeq(s).withValue(readLen):
    return readLen == 5 and s == "test"
  return false

proc ma1VB(vb: var VBuffer): bool =
  var temp: string
  vb.readSeq(temp).withValue(readLen):
    return readLen == 5 and temp == "test"
  return false

const TranscoderMA1 =
  Transcoder(stringToBuffer: ma1StB, bufferToString: ma1BtS, validateBuffer: ma1VB)

const AddressExts = [
  MAProtocol(
    mcodec: multiCodec("codec_mc1"), kind: Fixed, size: 4, coder: TranscoderMA1
  ),
  MAProtocol(mcodec: multiCodec("ip4"), kind: Fixed, size: 4, coder: TranscoderMA1),
]
