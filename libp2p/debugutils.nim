## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

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
import os, options
import nimcrypto/utils, stew/endians2
import protobuf/minprotobuf, stream/connection, protocols/secure/secure,
       multiaddress, peerid, varint, muxers/mplex/coder

from times import getTime, toUnix, fromUnix, nanosecond, format, Time,
                  NanosecondRange, initTime
from strutils import toHex, repeat
export peerid, options, multiaddress

type
  FlowDirection* = enum
    Outgoing, Incoming

  ProtoMessage* = object
    timestamp*: uint64
    direction*: FlowDirection
    message*: seq[byte]
    seqID*: Option[uint64]
    mtype*: Option[uint64]
    local*: Option[MultiAddress]
    remote*: Option[MultiAddress]

const
  libp2p_dump_dir* {.strdefine.} = "nim-libp2p"
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

proc dumpMessage*(conn: SecureConn, direction: FlowDirection,
                  data: openArray[byte]) =
  ## Store unencrypted message ``data`` to dump file, all the metadata will be
  ## extracted from ``conn`` instance.
  var pb = initProtoBuffer(options = {WithVarintLength})
  pb.write(2, getTimestamp())
  pb.write(4, uint64(direction))
  pb.write(6, conn.observedAddr)
  pb.write(7, data)
  pb.finish()

  let dirName =
    if isAbsolute(libp2p_dump_dir):
      libp2p_dump_dir
    else:
      getHomeDir() / libp2p_dump_dir

  let fileName = $(conn.peerId) & ".pbcap"

  # This is debugging procedure so it should not generate any exceptions,
  # and we going to return at every possible OS error.
  if not(dirExists(dirName)):
    try:
      createDir(dirName)
    except CatchableError:
      return

  let pathName = dirName / fileName
  var handle: File
  try:
    if open(handle, pathName, fmAppend):
      discard writeBuffer(handle, addr pb.buffer[pb.offset], pb.getLen())
  finally:
    close(handle)

proc decodeDumpMessage*(data: openArray[byte]): Option[ProtoMessage] =
  ## Decode protobuf's message ProtoMessage from array of bytes ``data``.
  var
    pb = initProtoBuffer(data)
    value: uint64
    ma1, ma2: MultiAddress
    pmsg: ProtoMessage

  let res2 = pb.getField(2, pmsg.timestamp)
  if res2.isErr() or not(res2.get()):
    return none[ProtoMessage]()

  let res4 = pb.getField(4, value)
  if res4.isErr() or not(res4.get()):
    return none[ProtoMessage]()

  # `case` statement could not work here with an error "selector must be of an
  # ordinal type, float or string"
  pmsg.direction =
    if value == uint64(Outgoing):
      Outgoing
    elif value == uint64(Incoming):
      Incoming
    else:
      return none[ProtoMessage]()

  let res7 = pb.getField(7, pmsg.message)
  if res7.isErr() or not(res7.get()):
    return none[ProtoMessage]()

  value = 0'u64
  let res1 = pb.getField(1, value)
  if res1.isOk() and res1.get():
    pmsg.seqID = some(value)
  value = 0'u64
  let res3 = pb.getField(3, value)
  if res3.isOk() and res3.get():
    pmsg.mtype = some(value)
  let res5 = pb.getField(5, ma1)
  if res5.isOk() and res5.get():
    pmsg.local = some(ma1)
  let res6 = pb.getField(6, ma2)
  if res6.isOk() and res6.get():
    pmsg.remote = some(ma2)

  some(pmsg)

iterator messages*(data: seq[byte]): Option[ProtoMessage] =
  ## Iterate over sequence of bytes and decode all the ``ProtoMessage``
  ## messages we found.
  var value: uint64
  var size: int
  var offset = 0
  while offset < len(data):
    value = 0
    size = 0
    let res = PB.getUVarint(data.toOpenArray(offset, len(data) - 1),
                            size, value)
    if res.isOk():
      if (value > 0'u64) and (value < uint64(len(data) - offset)):
        offset += size
        yield decodeDumpMessage(data.toOpenArray(offset,
                                                 offset + int(value) - 1))
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
      ascii.add(if ord(ch) > 31 and ord(ch) < 127: char(ch) else: '.')

    let item =
      case groupBy:
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
    let spacesCount = ((16 - (offset mod 16)) div groupBy) *
                        (groupBy * 2 + 1) + 1
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
    of Incoming:
      " << "
    of Outgoing:
      " >> "
  let address =
    block:
      let local =
        if msg.local.isSome():
          "[" & $(msg.local.get()) & "]"
        else:
          "[LOCAL]"
      let remote =
        if msg.remote.isSome():
          "[" & $(msg.remote.get()) & "]"
        else:
          "[REMOTE]"
      local & direction & remote
  let seqid =
    if msg.seqID.isSome():
      "seqID = " & $(msg.seqID.get()) & " "
    else:
      ""
  let mtype =
    if msg.mtype.isSome():
      "type = " & $(msg.mtype.get()) & " "
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
