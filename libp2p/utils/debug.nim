# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## To enable dump of all incoming and outgoing unencrypted messages you need
## to compile project with ``-d:libp2p_dump`` compile-time option. When this
## option enabled ``nim-libp2p`` will create dumps of unencrypted messages for
## every peer libp2p communicates.
##
## Every file is created with name "<PeerId>.pbcap". One file represents
## all the communication with peer which identified by ``PeerId``.
##
## File can have multiple protobuf encoded messages of this format:
##
## Protobuf's message fields:
##   1. SeqID: optional uint64
##   2. Timestamp: required uint64
##   3. Type: optional uint64
##   4. Direction: required uint64
##   5. LocalAddress: optional bytes
##   6. RemoteAddress: optional bytes
##   7. Message: required bytes
import os
import nimcrypto/utils, stew/endians2
import
  protobuf_serialization,
  protobuf_serialization/pkg/results,
  protobuf_serialization/std/enums,
  stream/connection,
  protocols/secure/secure,
  multiaddress,
  peerid,
  varint,
  muxers/mplex/coder

from times import
  getTime, toUnix, fromUnix, nanosecond, format, Time, NanosecondRange, initTime
from strutils import toHex, repeat
export peerid, multiaddress

type
  FlowDirection* = enum
    Outgoing
    Incoming

  ProtoMessage* {.proto2.} = object
    seqID* {.fieldNumber: 1, pint.}: Opt[uint64]
    timestamp* {.fieldNumber: 2, required, pint.}: uint64
    mtype* {.fieldNumber: 3, pint.}: Opt[uint64]
    direction* {.fieldNumber: 4, required, ext.}: FlowDirection
    local* {.fieldNumber: 5, ext.}: Opt[MultiAddress]
    remote* {.fieldNumber: 6, ext.}: Opt[MultiAddress]
    message* {.fieldNumber: 7, required.}: seq[byte]

const libp2p_dump_dir* {.strdefine.} = "nim-libp2p"
  ## default directory where all the dumps will be stored, if the path
  ## relative it will be created in home directory. You can overload this path
  ## using ``-d:libp2p_dump_dir=<otherpath>``.

proc getTimestamp(): uint64 =
  ## This procedure is present because `stdlib.times` missing it.
  let time = getTime()
  uint64(time.toUnix() * 1_000_000_000 + time.nanosecond())

proc getTimedate(value: uint64): string =
  ## This procedure is workaround for `stdlib.times` to just convert
  ## nanoseconds' timestamp to DateTime object.
  let time = initTime(int64(value div 1_000_000_000), value mod 1_000_000_000)
  time.format("yyyy-MM-dd HH:mm:ss'.'fffzzz")

proc dumpMessage*(conn: SecureConn, direction: FlowDirection, data: openArray[byte]) =
  ## Store unencrypted message ``data`` to dump file, all the metadata will be
  ## extracted from ``conn`` instance.
  let pbMsg = ProtoMessage(
    timestamp: getTimestamp(),
    direction: direction,
    remote: conn.observedAddr,
    message: @data,
  )

  let bytes =
    try:
      var writer = ProtobufWriter.init(memoryOutput(), {VarIntLengthPrefix})
      writer.writeValue(pbMsg)
      writer.finish()
    except IOError:
      return

  let dirName =
    if isAbsolute(libp2p_dump_dir):
      libp2p_dump_dir
    else:
      getHomeDir() / libp2p_dump_dir

  let fileName = $(conn.peerId) & ".pbcap"

  # This is debugging procedure so it should not generate any exceptions,
  # and we going to return at every possible OS error.
  if not (dirExists(dirName)):
    try:
      createDir(dirName)
    except CatchableError:
      return

  let pathName = dirName / fileName
  var handle: File
  try:
    if open(handle, pathName, fmAppend):
      if bytes.len > 0:
        discard writeBuffer(handle, unsafeAddr bytes[0], bytes.len)
  finally:
    close(handle)

proc decodeDumpMessage*(data: openArray[byte]): Opt[ProtoMessage] =
  ## Decode protobuf's message ProtoMessage from array of bytes ``data``.
  try:
    Opt.some(decode(Protobuf, @data, ProtoMessage))
  except SerializationError, IOError:
    Opt.none(ProtoMessage)

iterator messages*(data: seq[byte]): Opt[ProtoMessage] =
  ## Iterate over sequence of bytes and decode all the ``ProtoMessage``
  ## messages we found.
  var value: uint64
  var size: int
  var offset = 0
  while offset < len(data):
    value = 0
    size = 0
    let res = PB.getUVarint(data.toOpenArray(offset, len(data) - 1), size, value)
    if res.isOk():
      if (value > 0'u64) and (value < uint64(len(data) - offset)):
        offset += size
        yield decodeDumpMessage(data.toOpenArray(offset, offset + int(value) - 1))
        # value is previously checked to be less then len(data) which is `int`.
        offset += int(value)
      else:
        break
    else:
      break

proc dumpHex*(pbytes: openArray[byte], groupBy = 1, ascii = true): string =
  ## Get hexadecimal dump of memory for array ``pbytes``.
  var res = ""
  var offset = 0
  var ascii = ""

  while offset < len(pbytes):
    if (offset mod 16) == 0:
      res = res & toHex(uint64(offset)) & ":  "

    for k in 0 ..< groupBy:
      let ch = pbytes[offset + k]
      ascii.add(
        if ord(ch) > 31 and ord(ch) < 127:
          char(ch)
        else:
          '.'
      )

    let item =
      case groupBy
      of 1:
        toHex(pbytes[offset])
      of 2:
        toHex(uint16.fromBytes(pbytes.toOpenArray(offset, len(pbytes) - 1)))
      of 4:
        toHex(uint32.fromBytes(pbytes.toOpenArray(offset, len(pbytes) - 1)))
      of 8:
        toHex(uint64.fromBytes(pbytes.toOpenArray(offset, len(pbytes) - 1)))
      else:
        ""
    res.add(item)
    res.add(" ")
    offset = offset + groupBy

    if (offset mod 16) == 0:
      res.add(" ")
      res.add(ascii)
      ascii.setLen(0)
      res.add("\p")

  if (offset mod 16) != 0:
    let spacesCount = ((16 - (offset mod 16)) div groupBy) * (groupBy * 2 + 1) + 1
    res = res & repeat(' ', spacesCount)
    res = res & ascii

  res.add("\p")
  res

proc mplexMessage*(data: seq[byte]): string =
  var value = 0'u64
  var size = 0
  let res = PB.getUVarint(data, size, value)
  if res.isOk():
    if size < len(data) and data[size] == 0x00'u8:
      let header = cast[MessageType](value and 0x07'u64)
      let ident = (value shr 3)
      "mplex: [" & $header & ", ident = " & $ident & "] "
    else:
      ""
  else:
    ""

proc toString*(msg: ProtoMessage, dump = true): string =
  ## Convert message ``msg`` to its string representation.
  ## If ``dump`` is ``true`` (default) full hexadecimal dump with ascii will be
  ## used, otherwise just a simple hexadecimal string will be printed.
  var res = getTimedate(msg.timestamp)
  let direction =
    case msg.direction
    of Incoming: " << "
    of Outgoing: " >> "
  let address = block:
    let local = block:
      msg.local.withValue(loc):
        "[" & $loc & "]"
      else:
        "[LOCAL]"
    let remote = block:
      msg.remote.withValue(rem):
        "[" & $rem & "]"
      else:
        "[REMOTE]"
    local & direction & remote
  let seqid = block:
    msg.seqID.withValue(seqid):
      "seqID = " & $seqid & " "
    else:
      ""
  let mtype = block:
    msg.mtype.withValue(typ):
      "type = " & $typ & " "
    else:
      ""
  res.add(" ")
  res.add(address)
  res.add(" ")
  res.add(mtype)
  res.add(seqid)
  res.add(mplexMessage(msg.message))
  res.add(" ")
  res.add("\p")
  if dump:
    res.add(dumpHex(msg.message))
  else:
    res.add(utils.toHex(msg.message))
    res.add("\p")
  res
