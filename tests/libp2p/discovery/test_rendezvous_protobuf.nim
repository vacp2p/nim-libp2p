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
    let originalCookie = Cookie(offset: 42'u64, ns: namespace)
    let decodedCookie = Protobuf.decode(Protobuf.encode(originalCookie), Cookie)
    check:
      decodedCookie.offset == originalCookie.offset
      decodedCookie.ns == originalCookie.ns
      Protobuf.encode(decodedCookie) == Protobuf.encode(originalCookie) # roundtrip again

  test "Cookie roundtrip without namespace":
    let originalCookie = Cookie(offset: 7'u64)
    let decodedCookie = Protobuf.decode(Protobuf.encode(originalCookie), Cookie)
    check:
      decodedCookie.offset == originalCookie.offset
      decodedCookie.ns.len == 0
      Protobuf.encode(decodedCookie) == Protobuf.encode(originalCookie)

  test "Register roundtrip with ttl":
    let originalRegister =
      Register(ns: namespace, signedPeerRecord: @[byte 1, 2, 3], ttl: 60'u64)
    let decodedRegister = Protobuf.decode(Protobuf.encode(originalRegister), Register)
    check:
      decodedRegister.ns == originalRegister.ns
      decodedRegister.signedPeerRecord == originalRegister.signedPeerRecord
      decodedRegister.ttl == originalRegister.ttl
      Protobuf.encode(decodedRegister) == Protobuf.encode(originalRegister)

  test "Register roundtrip without ttl":
    let originalRegister = Register(ns: namespace, signedPeerRecord: @[byte 4, 5])
    let decodedRegister = Protobuf.decode(Protobuf.encode(originalRegister), Register)
    check:
      decodedRegister.ns == originalRegister.ns
      decodedRegister.signedPeerRecord == originalRegister.signedPeerRecord
      decodedRegister.ttl == 0
      Protobuf.encode(decodedRegister) == Protobuf.encode(originalRegister)

  test "RegisterResponse roundtrip successful":
    let originalResponse = RegisterResponse(status: ResponseOk, text: "ok", ttl: 10'u64)
    let decodedResponse =
      Protobuf.decode(Protobuf.encode(originalResponse), RegisterResponse)
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.text == originalResponse.text
      decodedResponse.ttl == originalResponse.ttl
      Protobuf.encode(decodedResponse) == Protobuf.encode(originalResponse)

  test "RegisterResponse roundtrip failed":
    let originalResponse = RegisterResponse(status: ResponseInvalidNamespace)
    let decodedResponse =
      Protobuf.decode(Protobuf.encode(originalResponse), RegisterResponse)
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.text.len == 0
      decodedResponse.ttl == 0
      Protobuf.encode(decodedResponse) == Protobuf.encode(originalResponse)

  test "Unregister roundtrip":
    let originalUnregister = Unregister(ns: namespace)
    let decodedUnregister =
      Protobuf.decode(Protobuf.encode(originalUnregister), Unregister)
    check:
      decodedUnregister.ns == originalUnregister.ns
      Protobuf.encode(decodedUnregister) == Protobuf.encode(originalUnregister)

  test "Discover roundtrip with all optional fields":
    let originalDiscover =
      Discover(ns: namespace, limit: 5'u64, cookie: @[byte 1, 2, 3])
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
      decodedDiscover.ns.len == 0
      decodedDiscover.limit == 0
      decodedDiscover.cookie.len == 0

  test "DiscoverResponse roundtrip with registration":
    let registrationEntry = Register(ns: namespace, signedPeerRecord: @[byte 9])
    let originalResponse = DiscoverResponse(
      registrations: @[registrationEntry],
      cookie: @[byte 0xAA],
      status: ResponseOk,
      text: "t",
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
    let originalResponse = DiscoverResponse(status: ResponseInternalError)
    let decodedResponse =
      Protobuf.decode(Protobuf.encode(originalResponse), DiscoverResponse)
    check:
      decodedResponse.status == originalResponse.status
      decodedResponse.registrations.len == 0
      decodedResponse.cookie.len == 0
      decodedResponse.text.len == 0
      Protobuf.encode(decodedResponse) == Protobuf.encode(originalResponse)

  test "Message roundtrip Register variant":
    let registerPayload = Register(ns: namespace, signedPeerRecord: @[byte 1])
    let originalMessage = Message(msgType: MsgTypeRegister, register: registerPayload)
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.msgType == originalMessage.msgType
      decodedMessage.register.ns == registerPayload.ns

  test "Message roundtrip RegisterResponse variant":
    let registerResponsePayload = RegisterResponse(status: ResponseOk)
    let originalMessage = Message(
      msgType: MsgTypeRegisterResponse, registerResponse: registerResponsePayload
    )
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.msgType == originalMessage.msgType
      decodedMessage.registerResponse.status == registerResponsePayload.status

  test "Message roundtrip Unregister variant":
    let unregisterPayload = Unregister(ns: namespace)
    let originalMessage =
      Message(msgType: MsgTypeUnregister, unregister: unregisterPayload)
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.unregister.ns == unregisterPayload.ns

  test "Message roundtrip Discover variant":
    let discoverPayload = Discover(limit: 1'u64)
    let originalMessage = Message(msgType: MsgTypeDiscover, discover: discoverPayload)
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.discover.limit == discoverPayload.limit

  test "Message roundtrip DiscoverResponse variant":
    let discoverResponsePayload = DiscoverResponse(status: ResponseUnavailable)
    let originalMessage = Message(
      msgType: MsgTypeDiscoverResponse, discoverResponse: discoverResponsePayload
    )
    let decodedMessage = Protobuf.decode(Protobuf.encode(originalMessage), Message)
    check:
      decodedMessage.discoverResponse.status == discoverResponsePayload.status

  test "Message decode header only":
    var headerOnlyMessage = Message(msgType: MsgTypeRegister)
    let decodeResult = Protobuf.decode(Protobuf.encode(headerOnlyMessage), Message)
    check:
      decodeResult.register == default(Register)
