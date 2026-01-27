# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import results
import ../../../libp2p/[multiaddress, peerid, protobuf/minprotobuf, crypto/crypto]
import ../../../libp2p/protocols/kademlia_discovery/[types, protobuf]
import ../../tools/[unittest, crypto]
import ./utils.nim

suite "Kademlia Discovery Protobuf":
  test "Advertisement encode/decode - basic":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    let ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    checkEncodeDecode(ad)

  test "Advertisement encode/decode - with all fields":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    let ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[10'u8, 20, 30, 40],
      metadata: @[5'u8, 6, 7, 8],
      timestamp: 123456789,
    )
    checkEncodeDecode(ad)

  test "Advertisement encode/decode - multiple addresses":
    let maddrs =
      @[
        MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get(),
        MultiAddress.init("/ip4/192.168.1.1/tcp/4001").get(),
        MultiAddress.init("/ip6/::1/tcp/9000").get(),
        MultiAddress.init("/dns4/example.com/tcp/443").get(),
      ]
    let ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: maddrs,
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    checkEncodeDecode(ad)

  test "Ticket encode/decode - basic":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    let ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    let ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])
    checkEncodeDecode(ticket)

  test "Ticket encode/decode - with signature":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    let ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    let ticket = Ticket(
      ad: ad,
      t_init: 1000000,
      t_mod: 2000000,
      t_wait_for: 3000,
      signature: @[50'u8, 60, 70, 80],
    )
    checkEncodeDecode(ticket)

  test "Advertisement with empty addresses":
    let ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    checkEncodeDecode(ad)

  test "Ticket with zero timestamps":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    let ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    let ticket = Ticket(ad: ad, t_init: 0, t_mod: 0, t_wait_for: 0, signature: @[])
    checkEncodeDecode(ticket)
