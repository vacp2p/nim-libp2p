# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import results
import stew/objects
import ../../protobuf/minprotobuf

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

  Cookie* = object
    offset*: uint64
    ns*: Opt[string]

  Register* = object
    ns*: string
    signedPeerRecord*: seq[byte]
    ttl*: Opt[uint64] # in seconds

  RegisterResponse* = object
    status*: ResponseStatus
    text*: Opt[string]
    ttl*: Opt[uint64] # in seconds

  Unregister* = object
    ns*: string

  Discover* = object
    ns*: Opt[string]
    limit*: Opt[uint64]
    cookie*: Opt[seq[byte]]

  DiscoverResponse* = object
    registrations*: seq[Register]
    cookie*: Opt[seq[byte]]
    status*: ResponseStatus
    text*: Opt[string]

  Message* = object
    msgType*: MessageType
    register*: Opt[Register]
    registerResponse*: Opt[RegisterResponse]
    unregister*: Opt[Unregister]
    discover*: Opt[Discover]
    discoverResponse*: Opt[DiscoverResponse]

proc encode*(c: Cookie): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, c.offset)
  if c.ns.isSome():
    result.write(2, c.ns.get())
  result.finish()

proc encode*(r: Register): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, r.ns)
  result.write(2, r.signedPeerRecord)
  r.ttl.withValue(ttl):
    result.write(3, ttl)
  result.finish()

proc encode*(rr: RegisterResponse): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, rr.status.uint)
  rr.text.withValue(text):
    result.write(2, text)
  rr.ttl.withValue(ttl):
    result.write(3, ttl)
  result.finish()

proc encode*(u: Unregister): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, u.ns)
  result.finish()

proc encode*(d: Discover): ProtoBuffer =
  result = initProtoBuffer()
  if d.ns.isSome():
    result.write(1, d.ns.get())
  d.limit.withValue(limit):
    result.write(2, limit)
  d.cookie.withValue(cookie):
    result.write(3, cookie)
  result.finish()

proc encode*(dr: DiscoverResponse): ProtoBuffer =
  result = initProtoBuffer()
  for reg in dr.registrations:
    result.write(1, reg.encode())
  dr.cookie.withValue(cookie):
    result.write(2, cookie)
  result.write(3, dr.status.uint)
  dr.text.withValue(text):
    result.write(4, text)
  result.finish()

proc encode*(msg: Message): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, msg.msgType.uint)
  msg.register.withValue(register):
    result.write(2, register.encode())
  msg.registerResponse.withValue(registerResponse):
    result.write(3, registerResponse.encode())
  msg.unregister.withValue(unregister):
    result.write(4, unregister.encode())
  msg.discover.withValue(discover):
    result.write(5, discover.encode())
  msg.discoverResponse.withValue(discoverResponse):
    result.write(6, discoverResponse.encode())
  result.finish()

proc decode*(_: typedesc[Cookie], buf: seq[byte]): Opt[Cookie] =
  var
    c: Cookie
    ns: string
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, c.offset)
    r2 = pb.getField(2, ns)
  if r1.isErr() or r2.isErr():
    return Opt.none(Cookie)
  if r2.get(false):
    c.ns = Opt.some(ns)
  Opt.some(c)

proc decode*(_: typedesc[Register], buf: seq[byte]): Opt[Register] =
  var
    r: Register
    ttl: uint64
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, r.ns)
    r2 = pb.getRequiredField(2, r.signedPeerRecord)
    r3 = pb.getField(3, ttl)
  if r1.isErr() or r2.isErr() or r3.isErr():
    return Opt.none(Register)
  if r3.get(false):
    r.ttl = Opt.some(ttl)
  Opt.some(r)

proc decode*(_: typedesc[RegisterResponse], buf: seq[byte]): Opt[RegisterResponse] =
  var
    rr: RegisterResponse
    statusOrd: uint
    text: string
    ttl: uint64
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, statusOrd)
    r2 = pb.getField(2, text)
    r3 = pb.getField(3, ttl)
  if r1.isErr() or r2.isErr() or r3.isErr() or
      not checkedEnumAssign(rr.status, statusOrd):
    return Opt.none(RegisterResponse)
  if r2.get(false):
    rr.text = Opt.some(text)
  if r3.get(false):
    rr.ttl = Opt.some(ttl)
  Opt.some(rr)

proc decode*(_: typedesc[Unregister], buf: seq[byte]): Opt[Unregister] =
  var u: Unregister
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, u.ns)
  if r1.isErr():
    return Opt.none(Unregister)
  Opt.some(u)

proc decode*(_: typedesc[Discover], buf: seq[byte]): Opt[Discover] =
  var
    d: Discover
    limit: uint64
    cookie: seq[byte]
    ns: string
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getField(1, ns)
    r2 = pb.getField(2, limit)
    r3 = pb.getField(3, cookie)
  if r1.isErr() or r2.isErr() or r3.isErr:
    return Opt.none(Discover)
  if r1.get(false):
    d.ns = Opt.some(ns)
  if r2.get(false):
    d.limit = Opt.some(limit)
  if r3.get(false):
    d.cookie = Opt.some(cookie)
  Opt.some(d)

proc decode*(_: typedesc[DiscoverResponse], buf: seq[byte]): Opt[DiscoverResponse] =
  var
    dr: DiscoverResponse
    registrations: seq[seq[byte]]
    cookie: seq[byte]
    statusOrd: uint
    text: string
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRepeatedField(1, registrations)
    r2 = pb.getField(2, cookie)
    r3 = pb.getRequiredField(3, statusOrd)
    r4 = pb.getField(4, text)
  if r1.isErr() or r2.isErr() or r3.isErr or r4.isErr() or
      not checkedEnumAssign(dr.status, statusOrd):
    return Opt.none(DiscoverResponse)
  for reg in registrations:
    var r: Register
    let regOpt = Register.decode(reg).valueOr:
      return
    dr.registrations.add(regOpt)
  if r2.get(false):
    dr.cookie = Opt.some(cookie)
  if r4.get(false):
    dr.text = Opt.some(text)
  Opt.some(dr)

proc decode*(_: typedesc[Message], buf: seq[byte]): Opt[Message] =
  var
    msg: Message
    statusOrd: uint
    pbr, pbrr, pbu, pbd, pbdr: ProtoBuffer
  let pb = initProtoBuffer(buf)

  ?pb.getRequiredField(1, statusOrd).toOpt
  if not checkedEnumAssign(msg.msgType, statusOrd):
    return Opt.none(Message)

  if ?pb.getField(2, pbr).optValue:
    msg.register = Register.decode(pbr.buffer)
    if msg.register.isNone():
      return Opt.none(Message)

  if ?pb.getField(3, pbrr).optValue:
    msg.registerResponse = RegisterResponse.decode(pbrr.buffer)
    if msg.registerResponse.isNone():
      return Opt.none(Message)

  if ?pb.getField(4, pbu).optValue:
    msg.unregister = Unregister.decode(pbu.buffer)
    if msg.unregister.isNone():
      return Opt.none(Message)

  if ?pb.getField(5, pbd).optValue:
    msg.discover = Discover.decode(pbd.buffer)
    if msg.discover.isNone():
      return Opt.none(Message)

  if ?pb.getField(6, pbdr).optValue:
    msg.discoverResponse = DiscoverResponse.decode(pbdr.buffer)
    if msg.discoverResponse.isNone():
      return Opt.none(Message)

  Opt.some(msg)
