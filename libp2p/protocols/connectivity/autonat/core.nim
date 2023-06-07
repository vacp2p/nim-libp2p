# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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
    id*: Opt[PeerId]
    addrs*: seq[MultiAddress]

  AutonatDial* = object
    peerInfo*: Opt[AutonatPeerInfo]

  AutonatDialResponse* = object
    status*: ResponseStatus
    text*: Opt[string]
    ma*: Opt[MultiAddress]

  AutonatMsg* = object
    msgType*: MsgType
    dial*: Opt[AutonatDial]
    response*: Opt[AutonatDialResponse]

  NetworkReachability* {.pure.} = enum
    Unknown, NotReachable, Reachable

proc encode(p: AutonatPeerInfo): ProtoBuffer =
  result = initProtoBuffer()
  p.id.withValue(id):
    result.write(1, id)
  for ma in p.addrs:
    result.write(2, ma.data.buffer)
  result.finish()

proc encode*(d: AutonatDial): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, MsgType.Dial.uint)
  var dial = initProtoBuffer()
  d.peerInfo.withValue(pinfo):
    dial.write(1, encode(pinfo))
  dial.finish()
  result.write(2, dial.buffer)
  result.finish()

proc encode*(r: AutonatDialResponse): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, MsgType.DialResponse.uint)
  var bufferResponse = initProtoBuffer()
  bufferResponse.write(1, r.status.uint)
  r.text.withValue(text):
    bufferResponse.write(2, text)
  r.ma.withValue(ma):
    bufferResponse.write(3, ma)
  bufferResponse.finish()
  result.write(3, bufferResponse.buffer)
  result.finish()

proc encode*(msg: AutonatMsg): ProtoBuffer =
  msg.dial.withValue(dial):
    return encode(dial)
  msg.response.withValue(res):
    return encode(res)

proc decode*(_: typedesc[AutonatMsg], buf: seq[byte]): Opt[AutonatMsg] =
  var
    msgTypeOrd: uint32
    pbDial: ProtoBuffer
    pbResponse: ProtoBuffer
    msg: AutonatMsg

  let pb = initProtoBuffer(buf)

  if ? pb.getField(1, msgTypeOrd).toOpt() and not checkedEnumAssign(msg.msgType, msgTypeOrd):
    return Opt.none(AutonatMsg)
  if ? pb.getField(2, pbDial).toOpt():
    var
      pbPeerInfo: ProtoBuffer
      dial: AutonatDial
    let r4 = ? pbDial.getField(1, pbPeerInfo).toOpt()

    var peerInfo: AutonatPeerInfo
    if r4:
      var pid: PeerId
      let
        r5 = ? pbPeerInfo.getField(1, pid).toOpt()
        r6 = ? pbPeerInfo.getRepeatedField(2, peerInfo.addrs).toOpt()
      if r5: peerInfo.id = Opt.some(pid)
      dial.peerInfo = Opt.some(peerInfo)
    msg.dial = Opt.some(dial)

  if ? pb.getField(3, pbResponse).toOpt():
    var
      statusOrd: uint
      text: string
      ma: MultiAddress
      response: AutonatDialResponse

    let
      r4 = ? pbResponse.getField(1, statusOrd).toOpt()
      r5 = ? pbResponse.getField(2, text).toOpt()
      r6 = ? pbResponse.getField(3, ma).toOpt()

    if r4 and not checkedEnumAssign(response.status, statusOrd):
      return Opt.none(AutonatMsg)
    if r5: response.text = Opt.some(text)
    if r6: response.ma = Opt.some(ma)
    msg.response = Opt.some(response)

  return Opt.some(msg)
