# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import results
import ../../../libp2p/[peerid, crypto/crypto, multiaddress]
import ../../../libp2p/protocols/capability_discovery/types
import ../../../libp2p/protocols/kademlia/protobuf
import ../../tools/[unittest, crypto]

suite "Kademlia Discovery Signatures":
  test "Ticket sign and verify with matching key":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket = Ticket(
      advertisement: ad, tInit: 1000000, tMod: 2000000, tWaitFor: 3000, signature: @[]
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()
    check ticket.verify(publicKey) == true

  test "Ticket verification fails with wrong key":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket = Ticket(
      advertisement: ad, tInit: 1000000, tMod: 2000000, tWaitFor: 3000, signature: @[]
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let wrongPublicKey = PrivateKey.random(rng[]).get().getPublicKey().get()
    check ticket.verify(wrongPublicKey) == false

  test "Ticket verification fails with tampered tInit":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket = Ticket(
      advertisement: ad, tInit: 1000000, tMod: 2000000, tWaitFor: 3000, signature: @[]
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with tInit
    ticket.tInit = 9999999
    check ticket.verify(publicKey) == false

  test "Ticket verification fails with tampered tMod":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket = Ticket(
      advertisement: ad, tInit: 1000000, tMod: 2000000, tWaitFor: 3000, signature: @[]
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with tMod
    ticket.tMod = 8888888
    check ticket.verify(publicKey) == false

  test "Ticket verification fails with tampered tWaitFor":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = @[1'u8, 2, 3, 4]
    var ticket = Ticket(
      advertisement: ad, tInit: 1000000, tMod: 2000000, tWaitFor: 3000, signature: @[]
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with tWaitFor
    ticket.tWaitFor = 7777
    check ticket.verify(publicKey) == false
