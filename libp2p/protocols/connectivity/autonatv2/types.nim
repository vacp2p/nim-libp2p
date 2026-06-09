# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import results, chronos
import
  protobuf_serialization,
  protobuf_serialization/pkg/results,
  protobuf_serialization/std/enums
import ../../../[multiaddress, peerid]
import ../../../utils/protobuf
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

  DialRequest* {.proto2.} = object
    addrs* {.fieldNumber: 1, ext.}: seq[MultiAddress]
    nonce* {.fieldNumber: 2, pint.}: Opt[Nonce]

  DialResponse* {.proto2.} = object
    status* {.fieldNumber: 1, ext.}: Opt[ResponseStatus]
    addrIdx* {.fieldNumber: 2, pint.}: Opt[AddrIdx]
    dialStatus* {.fieldNumber: 3, ext.}: Opt[DialStatus]

  DialBack* {.proto2.} = object
    nonce* {.fieldNumber: 1, pint.}: Opt[Nonce]

  DialBackResponse* {.proto2.} = object
    status* {.fieldNumber: 1, ext.}: Opt[DialBackStatus]

  DialDataRequest* {.proto2.} = object
    addrIdx* {.fieldNumber: 1, pint.}: Opt[AddrIdx]
    numBytes* {.fieldNumber: 2, pint.}: Opt[NumBytes]

  DialDataResponse* {.proto2.} = object
    data* {.fieldNumber: 1.}: Opt[seq[byte]]

  AutonatV2Msg* {.proto2.} = object
    dialReq* {.fieldNumber: 1.}: Opt[DialRequest]
    dialResp* {.fieldNumber: 2.}: Opt[DialResponse]
    dialDataReq* {.fieldNumber: 3.}: Opt[DialDataRequest]
    dialDataResp* {.fieldNumber: 4.}: Opt[DialDataResponse]

Protobuf.serializerFor(
  [
    DialRequest, DialResponse, DialBack, DialBackResponse, DialDataRequest,
    DialDataResponse, AutonatV2Msg,
  ]
)

# Custom `==` is needed to ensure consistent comparison with Opt-based fields
proc `==`*(a, b: AutonatV2Msg): bool =
  a.encode() == b.encode()
