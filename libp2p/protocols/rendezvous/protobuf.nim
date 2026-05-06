# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import
  std/macros,
  results,
  protobuf_serialization,
  protobuf_serialization/pkg/results,
  protobuf_serialization/std/enums,
  ../../protobuf/utils

export results

# Implements https://github.com/libp2p/specs/blob/master/rendezvous/README.md#protobuf

type
  MessageType* {.pure.} = enum
    Register = 0
    RegisterResponse = 1
    Unregister = 2
    Discover = 3
    DiscoverResponse = 4

  ResponseStatus* = enum
    Ok = 0
    InvalidNamespace = 100
    InvalidSignedPeerRecord = 101
    InvalidTTL = 102
    InvalidCookie = 103
    NotAuthorized = 200
    InternalError = 300
    Unavailable = 400

  Cookie* {.proto2.} = object
    offset* {.fieldNumber: 1, required, pint.}: uint64
    ns* {.fieldNumber: 2.}: Opt[string]

  Register* {.proto2.} = object
    ns* {.fieldNumber: 1, required.}: string
    signedPeerRecord* {.fieldNumber: 2, required.}: seq[byte]
    ttl* {.fieldNumber: 3, pint.}: Opt[uint64] # in seconds

  RegisterResponse* {.proto2.} = object
    status* {.fieldNumber: 1, required, ext.}: ResponseStatus
    text* {.fieldNumber: 2.}: Opt[string]
    ttl* {.fieldNumber: 3, pint.}: Opt[uint64] # in seconds

  Unregister* {.proto2.} = object
    ns* {.fieldNumber: 1, required.}: string

  Discover* {.proto2.} = object
    ns* {.fieldNumber: 1.}: Opt[string]
    limit* {.fieldNumber: 2, pint.}: Opt[uint64]
    cookie* {.fieldNumber: 3.}: Opt[seq[byte]]

  DiscoverResponse* {.proto2.} = object
    registrations* {.fieldNumber: 1.}: seq[Register]
    cookie* {.fieldNumber: 2.}: Opt[seq[byte]]
    status* {.fieldNumber: 3, required, ext.}: ResponseStatus
    text* {.fieldNumber: 4.}: Opt[string]

  Message* {.proto2.} = object
    msgType* {.fieldNumber: 1, required, ext.}: MessageType
    register* {.fieldNumber: 2.}: Opt[Register]
    registerResponse* {.fieldNumber: 3.}: Opt[RegisterResponse]
    unregister* {.fieldNumber: 4.}: Opt[Unregister]
    discover* {.fieldNumber: 5.}: Opt[Discover]
    discoverResponse* {.fieldNumber: 6.}: Opt[DiscoverResponse]

Protobuf.serializerFor([
  Cookie,
  Register,
  RegisterResponse,
  Unregister,
  Discover,
  DiscoverResponse,
  Message
])
