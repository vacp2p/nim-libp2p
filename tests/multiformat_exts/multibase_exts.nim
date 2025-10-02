import stew/byteutils

proc mb1Decode(
    inbytes: openArray[char], outbytes: var openArray[byte], outlen: var int
): MultiBaseStatus =
  try:
    copyMem(addr outbytes[0], unsafeAddr inbytes[4], inbytes.len - 4)
    outlen = outbytes.len
    result = MultiBaseStatus.Success
  except CatchableError:
    result = MultiBaseStatus.Error

proc mb1Encode(
    inbytes: openArray[byte], outbytes: var openArray[char], outlen: var int
): MultiBaseStatus =
  try:
    let inp = "ext_".toBytes & @inbytes
    copyMem(addr outbytes[0], unsafeAddr inp[0], inp.len)
    outlen = inp.len
    result = MultiBaseStatus.Success
  except CatchableError:
    result = MultiBaseStatus.Error

proc mb1EncodeLen(length: int): int =
  length + 4

proc mb1DecodeLen(length: int): int =
  length - 4

const BaseExts = [
  MBCodec(name: "codec_mb1", code: chr(0x24), decr: mb1Decode, encr: mb1Encode, decl: mb1DecodeLen, encl: mb1EncodeLen),
  MBCodec(name: "identity", code: chr(0x00), decr: mb1Decode, encr: mb1Encode, decl: mb1DecodeLen, encl: mb1EncodeLen),
]
