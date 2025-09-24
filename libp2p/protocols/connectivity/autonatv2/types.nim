# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import results, chronos, chronicles
import
  ../../../multiaddress, ../../../peerid, ../../../protobuf/minprotobuf, ../../../switch
from ../autonat/types import NetworkReachability

export NetworkReachability

const
  DefaultDialTimeout*: Duration = 15.seconds
  DefaultAmplificationAttackDialTimeout*: Duration = 3.seconds
  DefaultDialDataSize*: uint64 = 50 * 1024 # 50 KiB > 50 KB
  AutonatV2MsgLpSize*: int = 1024
  DialBackLpSize*: int = 1024
  # readLp needs to receive more than 4096 bytes (since it's a DialDataResponse) + overhead
  DialDataResponseLpSize*: int = 5000

type
  AutonatV2Codec* {.pure.} = enum
    DialRequest = "/libp2p/autonat/2/dial-request"
    DialBack = "/libp2p/autonat/2/dial-back"

  AutonatV2Response* = object
    reachability*: NetworkReachability
    dialResp*: DialResponse
    addrs*: Opt[MultiAddress]

  AutonatV2Error* = object of LPError

  Nonce* = uint64

  AddrIdx* = uint32

  NumBytes* = uint64

  MsgType* {.pure.} = enum
    # DialBack and DialBackResponse are not defined as AutonatV2Msg as per the spec
    # likely because they are expected in response to some other message
    DialRequest
    DialResponse
    DialDataRequest
    DialDataResponse

  ResponseStatus* {.pure.} = enum
    EInternalError = 0
    ERequestRejected = 100
    EDialRefused = 101
    Ok = 200

  DialBackStatus* {.pure.} = enum
    Ok = 0

  DialStatus* {.pure.} = enum
    Unused = 0
    EDialError = 100
    EDialBackError = 101
    Ok = 200

  DialRequest* = object
    addrs*: seq[MultiAddress]
    nonce*: Nonce

  DialResponse* = object
    status*: ResponseStatus
    addrIdx*: Opt[AddrIdx]
    dialStatus*: Opt[DialStatus]

  DialBack* = object
    nonce*: Nonce

  DialBackResponse* = object
    status*: DialBackStatus

  DialDataRequest* = object
    addrIdx*: AddrIdx
    numBytes*: NumBytes

  DialDataResponse* = object
    data*: seq[byte]

  AutonatV2Msg* = object
    case msgType*: MsgType
    of MsgType.DialRequest:
      dialReq*: DialRequest
    of MsgType.DialResponse:
      dialResp*: DialResponse
    of MsgType.DialDataRequest:
      dialDataReq*: DialDataRequest
    of MsgType.DialDataResponse:
      dialDataResp*: DialDataResponse

# DialRequest
proc encode*(dialReq: DialRequest): ProtoBuffer =
  var encoded = initProtoBuffer()
  for ma in dialReq.addrs:
    encoded.write(1, ma.data.buffer)
  encoded.write(2, dialReq.nonce)
  encoded.finish()
  encoded

proc decode*(T: typedesc[DialRequest], pb: ProtoBuffer): Opt[T] =
  var
    addrs: seq[MultiAddress]
    nonce: Nonce
  if not ?pb.getRepeatedField(1, addrs).toOpt():
    return Opt.none(T)
  if not ?pb.getField(2, nonce).toOpt():
    return Opt.none(T)
  Opt.some(T(addrs: addrs, nonce: nonce))

# DialResponse
proc encode*(dialResp: DialResponse): ProtoBuffer =
  var encoded = initProtoBuffer()
  encoded.write(1, dialResp.status.uint)
    # minprotobuf casts uses float64 for fixed64 fields
  dialResp.addrIdx.withValue(addrIdx):
    encoded.write(2, addrIdx)
  dialResp.dialStatus.withValue(dialStatus):
    encoded.write(3, dialStatus.uint)
  encoded.finish()
  encoded

proc decode*(T: typedesc[DialResponse], pb: ProtoBuffer): Opt[T] =
  var
    status: uint
    addrIdx: AddrIdx
    dialStatus: uint

  if not ?pb.getField(1, status).toOpt():
    return Opt.none(T)

  var optAddrIdx = Opt.none(AddrIdx)
  if ?pb.getField(2, addrIdx).toOpt():
    optAddrIdx = Opt.some(addrIdx)

  var optDialStatus = Opt.none(DialStatus)
  if ?pb.getField(3, dialStatus).toOpt():
    optDialStatus = Opt.some(cast[DialStatus](dialStatus))

  Opt.some(
    T(
      status: cast[ResponseStatus](status),
      addrIdx: optAddrIdx,
      dialStatus: optDialStatus,
    )
  )

# DialBack
proc encode*(dialBack: DialBack): ProtoBuffer =
  var encoded = initProtoBuffer()
  encoded.write(1, dialBack.nonce)
  encoded.finish()
  encoded

proc decode*(T: typedesc[DialBack], pb: ProtoBuffer): Opt[T] =
  var nonce: Nonce
  if not ?pb.getField(1, nonce).toOpt():
    return Opt.none(T)
  Opt.some(T(nonce: nonce))

# DialBackResponse
proc encode*(dialBackResp: DialBackResponse): ProtoBuffer =
  var encoded = initProtoBuffer()
  encoded.write(1, dialBackResp.status.uint)
  encoded.finish()
  encoded

proc decode*(T: typedesc[DialBackResponse], pb: ProtoBuffer): Opt[T] =
  var status: uint
  if not ?pb.getField(1, status).toOpt():
    return Opt.none(T)
  Opt.some(T(status: cast[DialBackStatus](status)))

# DialDataRequest
proc encode*(dialDataReq: DialDataRequest): ProtoBuffer =
  var encoded = initProtoBuffer()
  encoded.write(1, dialDataReq.addrIdx)
  encoded.write(2, dialDataReq.numBytes)
  encoded.finish()
  encoded

proc decode*(T: typedesc[DialDataRequest], pb: ProtoBuffer): Opt[T] =
  var
    addrIdx: AddrIdx
    numBytes: NumBytes
  if not ?pb.getField(1, addrIdx).toOpt():
    return Opt.none(T)
  if not ?pb.getField(2, numBytes).toOpt():
    return Opt.none(T)
  Opt.some(T(addrIdx: addrIdx, numBytes: numBytes))

# DialDataResponse
proc encode*(dialDataResp: DialDataResponse): ProtoBuffer =
  var encoded = initProtoBuffer()
  encoded.write(1, dialDataResp.data)
  encoded.finish()
  encoded

proc decode*(T: typedesc[DialDataResponse], pb: ProtoBuffer): Opt[T] =
  var data: seq[byte]
  if not ?pb.getField(1, data).toOpt():
    return Opt.none(T)
  Opt.some(T(data: data))

proc protoField(msgType: MsgType): int =
  case msgType
  of MsgType.DialRequest: 1.int
  of MsgType.DialResponse: 2.int
  of MsgType.DialDataRequest: 3.int
  of MsgType.DialDataResponse: 4.int

# AutonatV2Msg
proc encode*(msg: AutonatV2Msg): ProtoBuffer =
  var encoded = initProtoBuffer()
  case msg.msgType
  of MsgType.DialRequest:
    encoded.write(MsgType.DialRequest.protoField, msg.dialReq.encode())
  of MsgType.DialResponse:
    encoded.write(MsgType.DialResponse.protoField, msg.dialResp.encode())
  of MsgType.DialDataRequest:
    encoded.write(MsgType.DialDataRequest.protoField, msg.dialDataReq.encode())
  of MsgType.DialDataResponse:
    encoded.write(MsgType.DialDataResponse.protoField, msg.dialDataResp.encode())
  encoded.finish()
  encoded

proc decode*(T: typedesc[AutonatV2Msg], pb: ProtoBuffer): Opt[T] =
  var
    msgTypeOrd: uint32
    msg: ProtoBuffer

  if ?pb.getField(MsgType.DialRequest.protoField, msg).toOpt():
    let dialReq = DialRequest.decode(msg).valueOr:
      return Opt.none(AutonatV2Msg)
    Opt.some(AutonatV2Msg(msgType: MsgType.DialRequest, dialReq: dialReq))
  elif ?pb.getField(MsgType.DialResponse.protoField, msg).toOpt():
    let dialResp = DialResponse.decode(msg).valueOr:
      return Opt.none(AutonatV2Msg)
    Opt.some(AutonatV2Msg(msgType: MsgType.DialResponse, dialResp: dialResp))
  elif ?pb.getField(MsgType.DialDataRequest.protoField, msg).toOpt():
    let dialDataReq = DialDataRequest.decode(msg).valueOr:
      return Opt.none(AutonatV2Msg)
    Opt.some(AutonatV2Msg(msgType: MsgType.DialDataRequest, dialDataReq: dialDataReq))
  elif ?pb.getField(MsgType.DialDataResponse.protoField, msg).toOpt():
    let dialDataResp = DialDataResponse.decode(msg).valueOr:
      return Opt.none(AutonatV2Msg)
    Opt.some(
      AutonatV2Msg(msgType: MsgType.DialDataResponse, dialDataResp: dialDataResp)
    )
  else:
    Opt.none(AutonatV2Msg)

# Custom `==` is needed to compare since AutonatV2Msg is a case object
proc `==`*(a, b: AutonatV2Msg): bool =
  a.msgType == b.msgType and a.encode() == b.encode()
