proc coder1(data: openArray[byte], output: var openArray[byte]) =
  copyMem(addr output[0], unsafeAddr data[0], len(output))

proc coder2(data: openArray[byte], output: var openArray[byte]) =
  copyMem(addr output[0], unsafeAddr data[0], len(output))

proc sha2_256_override(data: openArray[byte], output: var openArray[byte]) =
  copyMem(addr output[0], unsafeAddr data[0], len(output))

const HashExts = [
  MHash(mcodec: multiCodec("codec_mc1"), size: 0, coder: coder1),
  MHash(mcodec: multiCodec("codec_mc2"), size: 6, coder: coder2),
  MHash(mcodec: multiCodec("sha2-256"), size: 6, coder: sha2_256_override),
]
