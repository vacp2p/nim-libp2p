# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../../libp2p/[protocols/rendezvous/protobuf]
import ../../tools/[unittest]

suite "RendezVous Protobuf":
  teardown:
    checkTrackers()

  const namespace = "ns"

  test "Cookie roundtrip":
    let original = Cookie(offset: 42'u64, ns: Opt.some(namespace))
    check Cookie.decode(original.encode()).tryGet() == original

  test "Register roundtrip":
    let original =
      Register(ns: namespace, signedPeerRecord: @[byte 1, 2, 3], ttl: Opt.some(60'u64))
    check Register.decode(original.encode()).tryGet() == original

  test "RegisterResponse roundtrip":
    let original = RegisterResponse(
      status: ResponseStatus.Ok, text: Opt.some("ok"), ttl: Opt.some(10'u64)
    )
    check RegisterResponse.decode(original.encode()).tryGet() == original

  test "Unregister roundtrip":
    let original = Unregister(ns: namespace)
    check Unregister.decode(original.encode()).tryGet() == original

  test "Discover roundtrip":
    let original = Discover(
      ns: Opt.some(namespace), limit: Opt.some(5'u64), cookie: Opt.some(@[byte 1, 2, 3])
    )
    check Discover.decode(original.encode()).tryGet() == original

  test "DiscoverResponse roundtrip":
    let registrationEntry = Register(ns: namespace, signedPeerRecord: @[byte 9])
    let original = DiscoverResponse(
      registrations: @[registrationEntry],
      cookie: Opt.some(@[byte 0xAA]),
      status: ResponseStatus.Ok,
      text: Opt.some("t"),
    )
    check DiscoverResponse.decode(original.encode()).tryGet() == original

  test "Message roundtrip Register variant":
    let registerPayload = Register(ns: namespace, signedPeerRecord: @[byte 1])
    let original =
      Message(msgType: MessageType.Register, register: Opt.some(registerPayload))
    check Message.decode(original.encode()).tryGet() == original
