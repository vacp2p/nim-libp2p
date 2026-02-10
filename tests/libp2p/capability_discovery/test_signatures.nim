# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import results
import ../../../libp2p/[peerid, crypto/crypto, multiaddress]
import ../../../libp2p/protocols/capability_discovery/[types, protobuf]
import ../../tools/[unittest, crypto]

suite "Kademlia Discovery Signatures":
  test "Ticket sign and verify with matching key":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()
    check ticket.verify(publicKey) == true

  test "Ticket verification fails with wrong key":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let wrongPublicKey = PrivateKey.random(rng[]).get().getPublicKey().get()
    check ticket.verify(wrongPublicKey) == false

  test "Ticket verification fails with tampered t_init":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with t_init
    ticket.t_init = 9999999
    check ticket.verify(publicKey) == false

  test "Ticket verification fails with tampered t_mod":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with t_mod
    ticket.t_mod = 8888888
    check ticket.verify(publicKey) == false

  test "Ticket verification fails with tampered t_wait_for":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with t_wait_for
    ticket.t_wait_for = 7777
    check ticket.verify(publicKey) == false
