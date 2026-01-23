# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

proc coder1(data: openArray[byte], output: var openArray[byte]) =
  let n = min(data.len, output.len)
  if n == 0:
    return
  copyMem(addr output[0], addr data[0], n)

proc coder2(data: openArray[byte], output: var openArray[byte]) =
  let n = min(data.len, output.len)
  if n == 0:
    return
  copyMem(addr output[0], addr data[0], n)

proc sha2_256_override(data: openArray[byte], output: var openArray[byte]) =
  let n = min(data.len, output.len)
  if n == 0:
    return
  copyMem(addr output[0], addr data[0], n)

const HashExts = [
  MHash(mcodec: multiCodec("codec_mc1"), size: 0, coder: coder1),
  MHash(mcodec: multiCodec("codec_mc2"), size: 6, coder: coder2),
  MHash(mcodec: multiCodec("sha2-256"), size: 6, coder: sha2_256_override),
]
