import stew/byteutils

proc ma1StB(s: string, vb: var VBuffer): bool =
  vb.writeSeq(s)
  return true

proc ma1BtS(vb: var VBuffer, s: var string): bool =
  if vb.readSeq(s) == 5 and s == "test":
    return true

proc ma1VB(vb: var VBuffer): bool =
  var temp: string
  if vb.readSeq(temp) == 5 and temp == "test":
    return true

const TranscoderMA1 =
  Transcoder(stringToBuffer: ma1StB, bufferToString: ma1BtS, validateBuffer: ma1VB)

const AddressExts = [
  MAProtocol(
    mcodec: multiCodec("codec_mc1"), kind: Fixed, size: 4, coder: TranscoderMA1
  ),
  MAProtocol(mcodec: multiCodec("ip4"), kind: Fixed, size: 4, coder: TranscoderMA1),
]
