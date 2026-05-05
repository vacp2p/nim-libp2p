# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import protobuf_serialization
import ../../../libp2p/[protocols/rendezvous/protobuf]
import ../../tools/[unittest]

suite "RendezVous Protobuf":
  teardown:
    checkTrackers()

  const namespace = "ns"

  test "Cookie roundtrip with namespace":
    let originalCookie = Cookie(offset: 42'u64, ns: Opt.some(namespace))
    let decodeResult = Cookie.decode(originalCookie.encode())
    check decodeResult.isSome()
    let decodedCookie = decodeResult.get()
    check:
      decodedCookie.offset == originalCookie.offset
      decodedCookie.ns.get() == originalCookie.ns.get()
      encode(decodedCookie) == encode(originalCookie) # roundtrip again

  test "Cookie roundtrip without namespace":
    let originalCookie = Cookie(offset: 7'u64)
    let decodeResult = Cookie.decode(originalCookie.encode())
    check decodeResult.isSome()
    let decodedCookie = decodeResult.get()
    check:
      decodedCookie.offset == originalCookie.offset
      decodedCookie.ns.isNone()
      encode(decodedCookie) == encode(originalCookie)

  test "Cookie decode fails when missing offset":
    check Cookie.decode(default(seq[byte])).isNone()

  test "Register roundtrip with ttl":
    let originalRegister =
      Register(ns: namespace, signedPeerRecord: @[byte 1, 2, 3], ttl: Opt.some(60'u64))
    let decodeResult = Register.decode(originalRegister.encode())
    check decodeResult.isSome()
    let decodedRegister = decodeResult.get()
    check:
      decodedRegister.ns == originalRegister.ns
      decodedRegister.signedPeerRecord == originalRegister.signedPeerRecord
      decodedRegister.ttl.get() == originalRegister.ttl.get()
      encode(decodedRegister) == encode(originalRegister)

  test "Register roundtrip without ttl":
    let originalRegister = Register(ns: namespace, signedPeerRecord: @[byte 4, 5])
    let decodeResult = Register.decode(encode(originalRegister))
    check decodeResult.isSome()
    let decodedRegister = decodeResult.get()
    check:
      decodedRegister.ns == originalRegister.ns
      decodedRegister.signedPeerRecord == originalRegister.signedPeerRecord
      decodedRegister.ttl.isNone()
      encode(decodedRegister) == encode(originalRegister)

  test "Register decode fails when missing namespace":
    type BadRegister {.proto2.} = object
      signedPeerRecord {.fieldNumber: 2, required.}: seq[byte]

    let encoded = Protobuf.encode(BadRegister(signedPeerRecord: @[byte 1]))
    check Register.decode(encoded).isNone()

  test "Register decode fails when missing signedPeerRecord":
    type BadRegister {.proto2.} = object
      ns {.fieldNumber: 1, required.}: string

    let encoded = Protobuf.encode(BadRegister(ns: namespace))
    check Register.decode(encoded).isNone()

  test "RegisterResponse roundtrip successful":
    let originalResponse = RegisterResponse(
      status: ResponseStatus.Ok, text: Opt.some("ok"), ttl: Opt.some(10'u64)
    )
    let decodeResult = RegisterResponse.decode(encode(originalResponse))
    check decodeResult.isSome()
    let decodedResponse = decodeResult.get()
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.text.get() == originalResponse.text.get()
      decodedResponse.ttl.get() == originalResponse.ttl.get()
      encode(decodedResponse) == encode(originalResponse)

  test "RegisterResponse roundtrip failed":
    let originalResponse = RegisterResponse(status: ResponseStatus.InvalidNamespace)
    let decodeResult = RegisterResponse.decode(encode(originalResponse))
    check decodeResult.isSome()
    let decodedResponse = decodeResult.get()
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.text.isNone()
      decodedResponse.ttl.isNone()
      encode(decodedResponse) == encode(originalResponse)

  test "RegisterResponse decode fails invalid status enum":
    type BadRegisterResponse {.proto2.} = object
      status {.fieldNumber: 1, required, pint.}: int32

    let encoded = Protobuf.encode(BadRegisterResponse(status: 999))
    check RegisterResponse.decode(encoded).isNone()

  test "RegisterResponse decode fails missing status":
    check RegisterResponse.decode(default(seq[byte])).isNone()

  test "Unregister roundtrip":
    let originalUnregister = Unregister(ns: namespace)
    let decodeResult = Unregister.decode(encode(originalUnregister))
    check decodeResult.isSome()
    let decodedUnregister = decodeResult.get()
    check:
      decodedUnregister.ns == originalUnregister.ns
      encode(decodedUnregister) == encode(originalUnregister)

  test "Unregister decode fails when missing namespace":
    check Unregister.decode(default(seq[byte])).isNone()

  test "Discover roundtrip with all optional fields":
    let originalDiscover = Discover(
      ns: Opt.some(namespace), limit: Opt.some(5'u64), cookie: Opt.some(@[byte 1, 2, 3])
    )
    let decodeResult = Discover.decode(encode(originalDiscover))
    check decodeResult.isSome()
    let decodedDiscover = decodeResult.get()
    check:
      decodedDiscover.ns.get() == originalDiscover.ns.get()
      decodedDiscover.limit.get() == originalDiscover.limit.get()
      decodedDiscover.cookie.get() == originalDiscover.cookie.get()
      encode(decodedDiscover) == encode(originalDiscover)

  test "Discover decode empty buffer yields empty object":
    var emptyDiscoverBuffer: seq[byte] = @[]
    let decodeResult = Discover.decode(emptyDiscoverBuffer)
    check decodeResult.isSome()
    let decodedDiscover = decodeResult.get()
    check:
      decodedDiscover.ns.isNone()
      decodedDiscover.limit.isNone()
      decodedDiscover.cookie.isNone()

  test "DiscoverResponse roundtrip with registration":
    let registrationEntry = Register(ns: namespace, signedPeerRecord: @[byte 9])
    let originalResponse = DiscoverResponse(
      registrations: @[registrationEntry],
      cookie: Opt.some(@[byte 0xAA]),
      status: ResponseStatus.Ok,
      text: Opt.some("t"),
    )
    let decodeResult = DiscoverResponse.decode(encode(originalResponse))
    check decodeResult.isSome()
    let decodedResponse = decodeResult.get()
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.registrations.len == 1
      decodedResponse.registrations[0].ns == registrationEntry.ns
      decodedResponse.cookie.get() == originalResponse.cookie.get()
      decodedResponse.text.get() == originalResponse.text.get()
      encode(decodedResponse) == encode(originalResponse)

  test "DiscoverResponse roundtrip failed":
    let originalResponse = DiscoverResponse(status: ResponseStatus.InternalError)
    let decodeResult = DiscoverResponse.decode(encode(originalResponse))
    check decodeResult.isSome()
    let decodedResponse = decodeResult.get()
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.registrations.len == 0
      decodedResponse.cookie.isNone()
      decodedResponse.text.isNone()
      encode(decodedResponse) == encode(originalResponse)

  test "DiscoverResponse decode fails with invalid registration":
    type BadDiscoverResponse {.proto2.} = object
      registrations {.fieldNumber: 1.}: seq[byte]
      status {.fieldNumber: 3, required, pint.}: int32

    let encoded =
      Protobuf.encode(BadDiscoverResponse(registrations: @[byte 0x00, 0xFF], status: 0))
    check DiscoverResponse.decode(encoded).isNone()

  test "DiscoverResponse decode fails missing status":
    check DiscoverResponse.decode(default(seq[byte])).isNone()

  test "Message roundtrip Register variant":
    let registerPayload = Register(ns: namespace, signedPeerRecord: @[byte 1])
    let originalMessage =
      Message(msgType: MessageType.Register, register: Opt.some(registerPayload))
    let decodeResult = Message.decode(encode(originalMessage))
    check decodeResult.isSome()
    let decodedMessage = decodeResult.get()
    check:
      decodedMessage.msgType == originalMessage.msgType
      decodedMessage.register.get().ns == registerPayload.ns

  test "Message roundtrip RegisterResponse variant":
    let registerResponsePayload = RegisterResponse(status: ResponseStatus.Ok)
    let originalMessage = Message(
      msgType: MessageType.RegisterResponse,
      registerResponse: Opt.some(registerResponsePayload),
    )
    let decodeResult = Message.decode(encode(originalMessage))
    check decodeResult.isSome()
    let decodedMessage = decodeResult.get()
    check:
      decodedMessage.msgType == originalMessage.msgType
      decodedMessage.registerResponse.get().status == registerResponsePayload.status

  test "Message roundtrip Unregister variant":
    let unregisterPayload = Unregister(ns: namespace)
    let originalMessage =
      Message(msgType: MessageType.Unregister, unregister: Opt.some(unregisterPayload))
    let decodeResult = Message.decode(encode(originalMessage))
    check decodeResult.isSome()
    let decodedMessage = decodeResult.get()
    check:
      decodedMessage.unregister.get().ns == unregisterPayload.ns

  test "Message roundtrip Discover variant":
    let discoverPayload = Discover(limit: Opt.some(1'u64))
    let originalMessage =
      Message(msgType: MessageType.Discover, discover: Opt.some(discoverPayload))
    let decodeResult = Message.decode(encode(originalMessage))
    check decodeResult.isSome()
    let decodedMessage = decodeResult.get()
    check:
      decodedMessage.discover.get().limit.get() == discoverPayload.limit.get()

  test "Message roundtrip DiscoverResponse variant":
    let discoverResponsePayload = DiscoverResponse(status: ResponseStatus.Unavailable)
    let originalMessage = Message(
      msgType: MessageType.DiscoverResponse,
      discoverResponse: Opt.some(discoverResponsePayload),
    )
    let decodeResult = Message.decode(encode(originalMessage))
    check decodeResult.isSome()
    let decodedMessage = decodeResult.get()
    check:
      decodedMessage.discoverResponse.get().status == discoverResponsePayload.status

  test "Message decode header only":
    var headerOnlyMessage = Message(msgType: MessageType.Register)
    let decodeResult = Message.decode(encode(headerOnlyMessage))
    check decodeResult.isSome()
    check:
      decodeResult.get().register.isNone()

  test "Message decode fails invalid msgType":
    type BadMessage {.proto2.} = object
      msgType {.fieldNumber: 1, required, pint.}: int32

    let encoded = Protobuf.encode(BadMessage(msgType: 999))
    check Message.decode(encoded).isNone()
