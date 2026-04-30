# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../../libp2p/[protocols/rendezvous/protobuf]
import ../../tools/[unittest]

suite "RendezVous Protobuf":
  teardown:
    checkTrackers()

  const namespace = "ns"

  test "Cookie roundtrip with namespace":
    let originalCookie = Cookie(offset: pbSome(42'u64), ns: pbSome(namespace))
    let decodedCookie = Protobuf.decode(Protobuf.encode(originalCookie), Cookie)
    check:
      decodedCookie.offset == originalCookie.offset
      decodedCookie.ns == originalCookie.ns
      Protobuf.encode(decodedCookie) == Protobuf.encode(originalCookie) # roundtrip again

  test "Cookie roundtrip without namespace":
    let originalCookie = Cookie(offset: pbSome(7'u64))
    let decodedCookie = Protobuf.decode(Protobuf.encode(originalCookie), Cookie)
    check:
      decodedCookie.offset == originalCookie.offset
      decodedCookie.ns.isNone()
      decodedCookie.ns.get().len == 0
      Protobuf.encode(decodedCookie) == Protobuf.encode(originalCookie)

  test "Register roundtrip with ttl":
    let originalRegister = Register(
      ns: pbSome(namespace),
      signedPeerRecord: pbSome(@[byte 1, 2, 3]),
      ttl: pbSome(60'u64),
    )
    let decodedRegister = Protobuf.decode(Protobuf.encode(originalRegister), Register)
    check:
      decodedRegister.ns == originalRegister.ns
      decodedRegister.signedPeerRecord == originalRegister.signedPeerRecord
      decodedRegister.ttl == originalRegister.ttl
      Protobuf.encode(decodedRegister) == Protobuf.encode(originalRegister)

  test "Register roundtrip without ttl":
    let originalRegister =
      Register(ns: pbSome(namespace), signedPeerRecord: pbSome(@[byte 4, 5]))
    let decodedRegister = Protobuf.decode(Protobuf.encode(originalRegister), Register)
    check:
      decodedRegister.ns == originalRegister.ns
      decodedRegister.signedPeerRecord == originalRegister.signedPeerRecord
      decodedRegister.ttl.isNone()
      decodedRegister.ttl.get() == 0
      Protobuf.encode(decodedRegister) == Protobuf.encode(originalRegister)

  test "RegisterResponse roundtrip successful":
    let originalResponse = RegisterResponse(
      status: pbSome(ResponseOk), text: pbSome("ok"), ttl: pbSome(10'u64)
    )
    let decodedResponse =
      Protobuf.decode(Protobuf.encode(originalResponse), RegisterResponse)
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.text == originalResponse.text
      decodedResponse.ttl == originalResponse.ttl
      Protobuf.encode(decodedResponse) == Protobuf.encode(originalResponse)

  test "RegisterResponse roundtrip failed":
    let originalResponse = RegisterResponse(status: pbSome(ResponseInvalidNamespace))
    let decodedResponse =
      Protobuf.decode(Protobuf.encode(originalResponse), RegisterResponse)
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.text.get().len == 0
      decodedResponse.ttl.get() == 0
      Protobuf.encode(decodedResponse) == Protobuf.encode(originalResponse)

  test "Unregister roundtrip":
    let originalUnregister = Unregister(ns: pbSome(namespace))
    let decodedUnregister =
      Protobuf.decode(Protobuf.encode(originalUnregister), Unregister)
    check:
      decodedUnregister.ns == originalUnregister.ns
      Protobuf.encode(decodedUnregister) == Protobuf.encode(originalUnregister)

  test "Discover roundtrip with all optional fields":
    let originalDiscover = Discover(
      ns: pbSome(namespace), limit: pbSome(5'u64), cookie: pbSome(@[byte 1, 2, 3])
    )
    let decodedDiscover = Protobuf.decode(Protobuf.encode(originalDiscover), Discover)
    check:
      decodedDiscover.ns == originalDiscover.ns
      decodedDiscover.limit == originalDiscover.limit
      decodedDiscover.cookie == originalDiscover.cookie
      Protobuf.encode(decodedDiscover) == Protobuf.encode(originalDiscover)

  test "Discover decode empty buffer yields empty object":
    var emptyDiscoverBuffer: seq[byte] = @[]
    let decodedDiscover = Protobuf.decode(emptyDiscoverBuffer, Discover)
    check:
      decodedDiscover.ns.isNone()
      decodedDiscover.limit.isNone()
      decodedDiscover.cookie.isNone()
      decodedDiscover.ns.get().len == 0
      decodedDiscover.limit.get() == 0
      decodedDiscover.cookie.get().len == 0

  test "DiscoverResponse roundtrip with registration":
    let registrationEntry =
      Register(ns: pbSome(namespace), signedPeerRecord: pbSome(@[byte 9]))
    let originalResponse = DiscoverResponse(
      registrations: @[registrationEntry],
      cookie: pbSome(@[byte 0xAA]),
      status: pbSome(ResponseOk),
      text: pbSome("t"),
    )
    let decodedResponse =
      Protobuf.decode(Protobuf.encode(originalResponse), DiscoverResponse)
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.registrations.len == 1
      decodedResponse.registrations[0].ns == registrationEntry.ns
      decodedResponse.cookie == originalResponse.cookie
      decodedResponse.text == originalResponse.text
      Protobuf.encode(decodedResponse) == Protobuf.encode(originalResponse)

  test "DiscoverResponse roundtrip failed":
    let originalResponse = DiscoverResponse(status: pbSome(ResponseInternalError))
    let decodedResponse =
      Protobuf.decode(Protobuf.encode(originalResponse), DiscoverResponse)
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.registrations.len == 0
      decodedResponse.cookie.isNone()
      decodedResponse.text.isNone()
      decodedResponse.cookie.get().len == 0
      decodedResponse.text.get().len == 0
      Protobuf.encode(decodedResponse) == Protobuf.encode(originalResponse)

  test "Message roundtrip Register variant":
    let registerPayload =
      Register(ns: pbSome(namespace), signedPeerRecord: pbSome(@[byte 1]))
    let originalMessage =
      Message(msgType: pbSome(MsgTypeRegister), register: pbSome(registerPayload))
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.msgType == originalMessage.msgType
      decodedMessage.register.get().ns == registerPayload.ns

  test "Message roundtrip RegisterResponse variant":
    let registerResponsePayload = RegisterResponse(status: pbSome(ResponseOk))
    let originalMessage = Message(
      msgType: pbSome(MsgTypeRegisterResponse),
      registerResponse: pbSome(registerResponsePayload),
    )
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.msgType == originalMessage.msgType
      decodedMessage.registerResponse.get().status == registerResponsePayload.status

  test "Message roundtrip Unregister variant":
    let unregisterPayload = Unregister(ns: pbSome(namespace))
    let originalMessage =
      Message(msgType: pbSome(MsgTypeUnregister), unregister: pbSome(unregisterPayload))
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.unregister.get().ns == unregisterPayload.ns

  test "Message roundtrip Discover variant":
    let discoverPayload = Discover(limit: pbSome(1'u64))
    let originalMessage =
      Message(msgType: pbSome(MsgTypeDiscover), discover: pbSome(discoverPayload))
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.discover.get().limit == discoverPayload.limit

  test "Message roundtrip DiscoverResponse variant":
    let discoverResponsePayload = DiscoverResponse(status: pbSome(ResponseUnavailable))
    let originalMessage = Message(
      msgType: pbSome(MsgTypeDiscoverResponse),
      discoverResponse: pbSome(discoverResponsePayload),
    )
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.discoverResponse.get().status == discoverResponsePayload.status

  test "Message decode header only":
    var headerOnlyMessage = Message(msgType: pbSome(MsgTypeRegister))
    let decodeResult = Protobuf.decode(Protobuf.encode(headerOnlyMessage), Message)
    check:
      decodeResult.register.get() == default(Register)
