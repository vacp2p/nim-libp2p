{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ../../libp2p/[protocols/rendezvous/protobuf]
import ../../libp2p/protobuf/minprotobuf
import ../helpers

suite "RendezVous Protobuf":
  teardown:
    checkTrackers()

  const namespace = "ns"

  test "Cookie roundtrip with namespace":
    let originalCookie = Cookie(offset: 42'u64, ns: Opt.some(namespace))
    let decodeResult = Cookie.decode(originalCookie.encode().buffer)
    check decodeResult.isSome()
    let decodedCookie = decodeResult.get()
    check:
      decodedCookie.offset == originalCookie.offset
      decodedCookie.ns.get() == originalCookie.ns.get()
      decodedCookie.encode().buffer == originalCookie.encode().buffer # roundtrip again

  test "Cookie roundtrip without namespace":
    let originalCookie = Cookie(offset: 7'u64)
    let decodeResult = Cookie.decode(originalCookie.encode().buffer)
    check decodeResult.isSome()
    let decodedCookie = decodeResult.get()
    check:
      decodedCookie.offset == originalCookie.offset
      decodedCookie.ns.isNone()
      decodedCookie.encode().buffer == originalCookie.encode().buffer

  test "Cookie decode fails when missing offset":
    var emptyCookieBuffer = initProtoBuffer()
    check Cookie.decode(emptyCookieBuffer.buffer).isNone()

  test "Register roundtrip with ttl":
    let originalRegister =
      Register(ns: namespace, signedPeerRecord: @[byte 1, 2, 3], ttl: Opt.some(60'u64))
    let decodeResult = Register.decode(originalRegister.encode().buffer)
    check decodeResult.isSome()
    let decodedRegister = decodeResult.get()
    check:
      decodedRegister.ns == originalRegister.ns
      decodedRegister.signedPeerRecord == originalRegister.signedPeerRecord
      decodedRegister.ttl.get() == originalRegister.ttl.get()
      decodedRegister.encode().buffer == originalRegister.encode().buffer

  test "Register roundtrip without ttl":
    let originalRegister = Register(ns: namespace, signedPeerRecord: @[byte 4, 5])
    let decodeResult = Register.decode(originalRegister.encode().buffer)
    check decodeResult.isSome()
    let decodedRegister = decodeResult.get()
    check:
      decodedRegister.ns == originalRegister.ns
      decodedRegister.signedPeerRecord == originalRegister.signedPeerRecord
      decodedRegister.ttl.isNone()
      decodedRegister.encode().buffer == originalRegister.encode().buffer

  test "Register decode fails when missing namespace":
    var bufferMissingNamespace = initProtoBuffer()
    bufferMissingNamespace.write(2, @[byte 1])
    check Register.decode(bufferMissingNamespace.buffer).isNone()

  test "Register decode fails when missing signedPeerRecord":
    var bufferMissingSignedPeerRecord = initProtoBuffer()
    bufferMissingSignedPeerRecord.write(1, namespace)
    check Register.decode(bufferMissingSignedPeerRecord.buffer).isNone()

  test "RegisterResponse roundtrip successful":
    let originalResponse = RegisterResponse(
      status: ResponseStatus.Ok, text: Opt.some("ok"), ttl: Opt.some(10'u64)
    )
    let decodeResult = RegisterResponse.decode(originalResponse.encode().buffer)
    check decodeResult.isSome()
    let decodedResponse = decodeResult.get()
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.text.get() == originalResponse.text.get()
      decodedResponse.ttl.get() == originalResponse.ttl.get()
      decodedResponse.encode().buffer == originalResponse.encode().buffer

  test "RegisterResponse roundtrip failed":
    let originalResponse = RegisterResponse(status: ResponseStatus.InvalidNamespace)
    let decodeResult = RegisterResponse.decode(originalResponse.encode().buffer)
    check decodeResult.isSome()
    let decodedResponse = decodeResult.get()
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.text.isNone()
      decodedResponse.ttl.isNone()
      decodedResponse.encode().buffer == originalResponse.encode().buffer

  test "RegisterResponse decode fails invalid status enum":
    var bufferInvalidStatusValue = initProtoBuffer()
    bufferInvalidStatusValue.write(1, uint(999))
    check RegisterResponse.decode(bufferInvalidStatusValue.buffer).isNone()

  test "RegisterResponse decode fails missing status":
    var bufferMissingStatusField = initProtoBuffer()
    bufferMissingStatusField.write(2, "msg")
    check RegisterResponse.decode(bufferMissingStatusField.buffer).isNone()

  test "Unregister roundtrip":
    let originalUnregister = Unregister(ns: namespace)
    let decodeResult = Unregister.decode(originalUnregister.encode().buffer)
    check decodeResult.isSome()
    let decodedUnregister = decodeResult.get()
    check:
      decodedUnregister.ns == originalUnregister.ns
      decodedUnregister.encode().buffer == originalUnregister.encode().buffer

  test "Unregister decode fails when missing namespace":
    var bufferMissingUnregisterNamespace = initProtoBuffer()
    check Unregister.decode(bufferMissingUnregisterNamespace.buffer).isNone()

  test "Discover roundtrip with all optional fields":
    let originalDiscover = Discover(
      ns: Opt.some(namespace), limit: Opt.some(5'u64), cookie: Opt.some(@[byte 1, 2, 3])
    )
    let decodeResult = Discover.decode(originalDiscover.encode().buffer)
    check decodeResult.isSome()
    let decodedDiscover = decodeResult.get()
    check:
      decodedDiscover.ns.get() == originalDiscover.ns.get()
      decodedDiscover.limit.get() == originalDiscover.limit.get()
      decodedDiscover.cookie.get() == originalDiscover.cookie.get()
      decodedDiscover.encode().buffer == originalDiscover.encode().buffer

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
    let decodeResult = DiscoverResponse.decode(originalResponse.encode().buffer)
    check decodeResult.isSome()
    let decodedResponse = decodeResult.get()
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.registrations.len == 1
      decodedResponse.registrations[0].ns == registrationEntry.ns
      decodedResponse.cookie.get() == originalResponse.cookie.get()
      decodedResponse.text.get() == originalResponse.text.get()
      decodedResponse.encode().buffer == originalResponse.encode().buffer

  test "DiscoverResponse roundtrip failed":
    let originalResponse = DiscoverResponse(status: ResponseStatus.InternalError)
    let decodeResult = DiscoverResponse.decode(originalResponse.encode().buffer)
    check decodeResult.isSome()
    let decodedResponse = decodeResult.get()
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.registrations.len == 0
      decodedResponse.cookie.isNone()
      decodedResponse.text.isNone()
      decodedResponse.encode().buffer == originalResponse.encode().buffer

  test "DiscoverResponse decode fails with invalid registration":
    var bufferInvalidRegistration = initProtoBuffer()
    bufferInvalidRegistration.write(1, @[byte 0x00, 0xFF])
    bufferInvalidRegistration.write(3, ResponseStatus.Ok.uint)
    check DiscoverResponse.decode(bufferInvalidRegistration.buffer).isNone()

  test "DiscoverResponse decode fails missing status":
    var bufferMissingDiscoverResponseStatus = initProtoBuffer()
    check DiscoverResponse.decode(bufferMissingDiscoverResponseStatus.buffer).isNone()

  test "Message roundtrip Register variant":
    let registerPayload = Register(ns: namespace, signedPeerRecord: @[byte 1])
    let originalMessage =
      Message(msgType: MessageType.Register, register: Opt.some(registerPayload))
    let decodeResult = Message.decode(originalMessage.encode().buffer)
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
    let decodeResult = Message.decode(originalMessage.encode().buffer)
    check decodeResult.isSome()
    let decodedMessage = decodeResult.get()
    check:
      decodedMessage.msgType == originalMessage.msgType
      decodedMessage.registerResponse.get().status == registerResponsePayload.status

  test "Message roundtrip Unregister variant":
    let unregisterPayload = Unregister(ns: namespace)
    let originalMessage =
      Message(msgType: MessageType.Unregister, unregister: Opt.some(unregisterPayload))
    let decodeResult = Message.decode(originalMessage.encode().buffer)
    check decodeResult.isSome()
    let decodedMessage = decodeResult.get()
    check:
      decodedMessage.unregister.get().ns == unregisterPayload.ns

  test "Message roundtrip Discover variant":
    let discoverPayload = Discover(limit: Opt.some(1'u64))
    let originalMessage =
      Message(msgType: MessageType.Discover, discover: Opt.some(discoverPayload))
    let decodeResult = Message.decode(originalMessage.encode().buffer)
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
    let decodeResult = Message.decode(originalMessage.encode().buffer)
    check decodeResult.isSome()
    let decodedMessage = decodeResult.get()
    check:
      decodedMessage.discoverResponse.get().status == discoverResponsePayload.status

  test "Message decode header only":
    var headerOnlyMessage = Message(msgType: MessageType.Register)
    let decodeResult = Message.decode(headerOnlyMessage.encode().buffer)
    check decodeResult.isSome()
    check:
      decodeResult.get().register.isNone()

  test "Message decode fails invalid msgType":
    var bufferInvalidMessageType = initProtoBuffer()
    bufferInvalidMessageType.write(1, uint(999))
    check Message.decode(bufferInvalidMessageType.buffer).isNone()
