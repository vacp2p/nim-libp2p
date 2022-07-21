# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## The switch is the core of libp2p, which brings together the
## transports, the connection manager, the upgrader and other
## parts to allow programs to use libp2p

{.push raises: [Defect].}

import strutils
import chronos, chronicles, protobuf_serialization
import ./discoveryinterface

logScope:
  topics = "libp2p discovery rendezvous"

type
  MessageType {.pure.} = enum
    Register = 0
    RegisterResponse = 1
    Unregister = 2
    Discover = 3
    DiscoverResponse = 4

  ResponseStatus = enum
    Ok = 0
    InvalidNamespace = 100
    InvalidSignedPeerRecord = 101
    InvalidTtl = 102
    InvalidCookie = 103
    NotAuthorized = 200
    InternalError = 300
    Unavailable = 400

  Register {.protobuf3.} = object
    ns {.fieldNumber: 1.}: Option[string]
    signedPeerRecord {.fieldNumber: 2.}: Option[seq[byte]]
    ttl {.pint, fieldNumber: 3.}: Option[uint64] # in seconds

  RegisterResponse {.protobuf3.} = object
    status {.fieldNumber: 1.}: Option[ResponseStatus]
    text {.fieldNumber: 2.}: Option[string]
    ttl {.pint, fieldNumber: 3.}: Option[uint64] # in seconds

  Unregister {.protobuf3.} = object
    ns {.fieldNumber: 1.}: Option[string]

  Discover {.protobuf3.} = object
    ns {.fieldNumber: 1.}: Option[string]
    limit {.pint, fieldNumber: 3.}: Option[uint64]
    cookie {.fieldNumber: 3.}: Option[seq[byte]]

  DiscoverResponse {.protobuf3.} = object
    registrations {.fieldNumber: 1.}: seq[Register]
    cookie {.fieldNumber: 2.}: Option[seq[byte]]
    status {.fieldNumber: 3.}: Option[ResponseStatus]
    text {.fieldNumber: 4.}: Option[string]

  Message {.protobuf3.} = object
    msgType {.fieldNumber: 1.}: Option[MessageType]
    register {.fieldNumber: 2.}: Option[Register]
    registerResponse {.fieldNumber: 3.}: Option[RegisterResponse]
    unregister {.fieldNumber: 4.}: Option[Unregister]
    discover {.fieldNumber: 5.}: Option[Discover]
    discoverResponse {.fieldNumber: 6.}: Option[DiscoverResponse]
