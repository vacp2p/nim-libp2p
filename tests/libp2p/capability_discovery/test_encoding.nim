# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import results
import ../../../libp2p/[multiaddress, peerid, protobuf/minprotobuf, crypto/crypto]
import ../../../libp2p/protocols/capability_discovery/[types, protobuf]
import ../../tools/unittest
import ./utils.nim

suite "Kademlia Discovery Protobuf":
  test "Ticket encode/decode - basic":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    let ad = @[1'u8, 2, 3, 4]
    let ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])
    checkEncodeDecode(ticket)

  test "Ticket encode/decode - with signature":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    let ad = @[1'u8, 2, 3, 4]
    let ticket = Ticket(
      ad: ad,
      t_init: 1000000,
      t_mod: 2000000,
      t_wait_for: 3000,
      signature: @[50'u8, 60, 70, 80],
    )
    checkEncodeDecode(ticket)

  test "Ticket with zero timestamps":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    let ad = @[1'u8, 2, 3, 4]
    let ticket = Ticket(ad: ad, t_init: 0, t_mod: 0, t_wait_for: 0, signature: @[])
    checkEncodeDecode(ticket)
