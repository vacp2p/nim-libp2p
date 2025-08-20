# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import stew/objects
import results, chronos, chronicles
import ../../../multiaddress, ../../../peerid, ../../../errors
import ../../../protobuf/minprotobuf

logScope:
  topics = "libp2p autonat v2"

const
  AutonatV2DialRequestCodec* = "/libp2p/autonat/2/dial-request"
  AutonatV2DialBackCodec* = "/libp2p/autonat/2/dial-back"

  MsgType* = enum
    DialRequest = 1
    DialResponse = 2
    DialDataRequest = 3
    DialDataResponse = 4

  ResponseStatus* = enum
    EInternalError = 0
    ERequestRejected = 100
    EDialRefused = 101
    Ok = 200

  DialBackStatus* = enum
    Ok = 0

  DialStatus* = enum
    Unused = 0
    EDialError = 100
    EDialBackError = 101
    Ok = 200

  DialRequest* = object
    addrs*: seq[MultiAddress]
    nonce*: uint64

  DialResponse* = object
    status*: ResponseStatus
    addrIdx*: uint32
    dialStatus*: DialStatus

  DialBack* = object
    nonce*: uint64

  DialBackResponse* = object
    status*: DialBackStatus

  DialDataRequest* = object
    addrIdx*: uint32
    numbBytes*: uint64

  DialDataResponse* = object
    data*: seq[byte]
