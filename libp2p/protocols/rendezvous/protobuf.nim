# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import protobuf_serialization

export protobuf_serialization

# Implements https://github.com/libp2p/specs/blob/master/rendezvous/README.md#protobuf

const
  MsgTypeRegister* = 0'u32
  MsgTypeRegisterResponse* = 1'u32
  MsgTypeUnregister* = 2'u32
  MsgTypeDiscover* = 3'u32
  MsgTypeDiscoverResponse* = 4'u32
  ResponseOk* = 0'u32
  ResponseInvalidNamespace* = 100'u32
  ResponseInvalidSignedPeerRecord* = 101'u32
  ResponseInvalidTTL* = 102'u32
  ResponseInvalidCookie* = 103'u32
  ResponseNotAuthorized* = 200'u32
  ResponseInternalError* = 300'u32
  ResponseUnavailable* = 400'u32

type
  MessageType* = uint32
  ResponseStatus* = uint32

  Cookie* {.proto2.} = object
    offset* {.fieldNumber: 1, pint.}: PBOption[0'u64]
    ns* {.fieldNumber: 2.}: PBOption[default(string)]

  Register* {.proto2.} = object
    ns* {.fieldNumber: 1.}: PBOption[default(string)]
    signedPeerRecord* {.fieldNumber: 2.}: PBOption[default(seq[byte])]
    ttl* {.fieldNumber: 3, pint.}: PBOption[0'u64] # in seconds

  RegisterResponse* {.proto2.} = object
    status* {.fieldNumber: 1, pint.}: PBOption[0'u32]
    text* {.fieldNumber: 2.}: PBOption[default(string)]
    ttl* {.fieldNumber: 3, pint.}: PBOption[0'u64] # in seconds

  Unregister* {.proto2.} = object
    ns* {.fieldNumber: 1.}: PBOption[default(string)]

  Discover* {.proto2.} = object
    ns* {.fieldNumber: 1.}: PBOption[default(string)]
    limit* {.fieldNumber: 2, pint.}: PBOption[0'u64]
    cookie* {.fieldNumber: 3.}: PBOption[default(seq[byte])]

  DiscoverResponse* {.proto2.} = object
    registrations* {.fieldNumber: 1.}: seq[Register]
    cookie* {.fieldNumber: 2.}: PBOption[default(seq[byte])]
    status* {.fieldNumber: 3, pint.}: PBOption[0'u32]
    text* {.fieldNumber: 4.}: PBOption[default(string)]

  Message* {.proto2.} = object
    msgType* {.fieldNumber: 1, pint.}: PBOption[0'u32]
    register* {.fieldNumber: 2.}: PBOption[default(Register)]
    registerResponse* {.fieldNumber: 3.}: PBOption[default(RegisterResponse)]
    unregister* {.fieldNumber: 4.}: PBOption[default(Unregister)]
    discover* {.fieldNumber: 5.}: PBOption[default(Discover)]
    discoverResponse* {.fieldNumber: 6.}: PBOption[default(DiscoverResponse)]
