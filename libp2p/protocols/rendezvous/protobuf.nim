# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import protobuf_serialization

export protobuf_serialization

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

  Cookie* {.proto3.} = object
    offset* {.fieldNumber: 1, pint.}: uint64
    ns* {.fieldNumber: 2.}: string

  Register* {.proto3.} = object
    ns* {.fieldNumber: 1.}: string
    signedPeerRecord* {.fieldNumber: 2.}: seq[byte]
    ttl* {.fieldNumber: 3, pint.}: uint64 # in seconds

  RegisterResponse* {.proto3.} = object
    status* {.fieldNumber: 1, pint.}: ResponseStatus
    text* {.fieldNumber: 2.}: string
    ttl* {.fieldNumber: 3, pint.}: uint64 # in seconds

  Unregister* {.proto3.} = object
    ns* {.fieldNumber: 1.}: string

  Discover* {.proto3.} = object
    ns* {.fieldNumber: 1.}: string
    limit* {.fieldNumber: 2, pint.}: uint64
    cookie* {.fieldNumber: 3.}: seq[byte]

  DiscoverResponse* {.proto3.} = object
    registrations* {.fieldNumber: 1.}: seq[Register]
    cookie* {.fieldNumber: 2.}: seq[byte]
    status* {.fieldNumber: 3, pint.}: ResponseStatus
    text* {.fieldNumber: 4.}: string

  Message* {.proto3.} = object
    msgType* {.fieldNumber: 1, pint.}: MessageType
    register* {.fieldNumber: 2.}: Register
    registerResponse* {.fieldNumber: 3.}: RegisterResponse
    unregister* {.fieldNumber: 4.}: Unregister
    discover* {.fieldNumber: 5.}: Discover
    discoverResponse* {.fieldNumber: 6.}: DiscoverResponse
