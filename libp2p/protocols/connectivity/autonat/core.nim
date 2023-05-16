# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options]
import stew/[results, objects]
import chronos, chronicles
import ../../../multiaddress,
       ../../../peerid,
       ../../../errors

logScope:
  topics = "libp2p autonat"

const
  AutonatCodec* = "/libp2p/autonat/1.0.0"
  AddressLimit* = 8

type
  AutonatError* = object of LPError
  AutonatUnreachableError* = object of LPError

  MsgType* = enum
    Dial = 0
    DialResponse = 1

  ResponseStatus* = enum
    Ok = 0
    DialError = 100
    DialRefused = 101
    BadRequest = 200
    InternalError = 300

  AutonatPeerInfo* = object
    id*: Option[PeerId]
    addrs*: seq[MultiAddress]

  AutonatDial* = object
    peerInfo*: Option[AutonatPeerInfo]

  AutonatDialResponse* = object
    status*: ResponseStatus
    text*: Option[string]
    ma*: Option[MultiAddress]

  AutonatMsg* = object
    msgType*: MsgType
    dial*: Option[AutonatDial]
    response*: Option[AutonatDialResponse]

  NetworkReachability* {.pure.} = enum
    Unknown, NotReachable, Reachable

proc encode(p: AutonatPeerInfo): ProtoBuffer =
  result = initProtoBuffer()
  if p.id.isSome():
    result.write(1, p.id.get())
  for ma in p.addrs:
    result.write(2, ma.data.buffer)
  result.finish()

proc encode*(d: AutonatDial): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, MsgType.Dial.uint)
  var dial = initProtoBuffer()
  if d.peerInfo.isSome():
    dial.write(1, encode(d.peerInfo.get()))
  dial.finish()
  result.write(2, dial.buffer)
  result.finish()

proc encode*(r: AutonatDialResponse): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, MsgType.DialResponse.uint)
  var bufferResponse = initProtoBuffer()
  bufferResponse.write(1, r.status.uint)
  if r.text.isSome():
    bufferResponse.write(2, r.text.get())
  if r.ma.isSome():
    bufferResponse.write(3, r.ma.get())
  bufferResponse.finish()
  result.write(3, bufferResponse.buffer)
  result.finish()

proc encode*(msg: AutonatMsg): ProtoBuffer =
  if msg.dial.isSome():
    return encode(msg.dial.get())
  if msg.response.isSome():
    return encode(msg.response.get())

proc decode*(_: typedesc[AutonatMsg], buf: seq[byte]): Option[AutonatMsg] =
  var
    msgTypeOrd: uint32
    pbDial: ProtoBuffer
    pbResponse: ProtoBuffer
    msg: AutonatMsg

  let
    pb = initProtoBuffer(buf)
    r1 = pb.getField(1, msgTypeOrd)
    r2 = pb.getField(2, pbDial)
    r3 = pb.getField(3, pbResponse)
  if r1.isErr() or r2.isErr() or r3.isErr(): return none(AutonatMsg)

  if r1.get() and not checkedEnumAssign(msg.msgType, msgTypeOrd):
    return none(AutonatMsg)
  if r2.get():
    var
      pbPeerInfo: ProtoBuffer
      dial: AutonatDial
    let
      r4 = pbDial.getField(1, pbPeerInfo)
    if r4.isErr(): return none(AutonatMsg)

    var peerInfo: AutonatPeerInfo
    if r4.get():
      var pid: PeerId
      let
        r5 = pbPeerInfo.getField(1, pid)
        r6 = pbPeerInfo.getRepeatedField(2, peerInfo.addrs)
      if r5.isErr() or r6.isErr(): return none(AutonatMsg)
      if r5.get(): peerInfo.id = some(pid)
      dial.peerInfo = some(peerInfo)
    msg.dial = some(dial)

  if r3.get():
    var
      statusOrd: uint
      text: string
      ma: MultiAddress
      response: AutonatDialResponse

    let
      r4 = pbResponse.getField(1, statusOrd)
      r5 = pbResponse.getField(2, text)
      r6 = pbResponse.getField(3, ma)

    if r4.isErr() or r5.isErr() or r6.isErr() or
       (r4.get() and not checkedEnumAssign(response.status, statusOrd)):
      return none(AutonatMsg)
    if r5.get(): response.text = some(text)
    if r6.get(): response.ma = some(ma)
    msg.response = some(response)

  return some(msg)