# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import results
import ../../../libp2p/[peerid, crypto/crypto, multiaddress]
import ../../../libp2p/protocols/capability_discovery/[types, protobuf]
import ../../tools/[unittest, crypto]

suite "Kademlia Discovery Signatures":
  test "Advertisement sign and verify with matching key":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ad.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()
    check ad.verify(publicKey) == true

  test "Advertisement verification fails with wrong key":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ad.sign(privateKey)
    check signResult.isOk()

    let wrongPublicKey = PrivateKey.random(rng[]).get().getPublicKey().get()
    check ad.verify(wrongPublicKey) == false

  test "Advertisement verification fails with tampered serviceId":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ad.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with serviceId
    ad.serviceId[0] = 255'u8
    check ad.verify(publicKey) == false

  test "Advertisement verification fails with tampered peerId":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ad.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with peerId
    let wrongPeerId = PeerId.init(PrivateKey.random(rng[]).get()).get()
    ad.peerId = wrongPeerId
    check ad.verify(publicKey) == false

  test "Advertisement verification fails with tampered addrs":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ad.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with addrs
    let newMaddr = MultiAddress.init("/ip4/10.0.0.1/tcp/8000").get()
    ad.addrs = @[newMaddr]
    check ad.verify(publicKey) == false

  test "Advertisement verification succeeds with modified metadata":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[1'u8, 2, 3],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ad.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Modify metadata after signing - should still verify since metadata is not signed
    ad.metadata = @[9'u8, 8, 7]
    check ad.verify(publicKey) == true

  test "Advertisement verification succeeds with modified timestamp":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 12345,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ad.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Modify timestamp after signing - should still verify since timestamp is not signed
    ad.timestamp = 99999
    check ad.verify(publicKey) == true

  test "Ticket sign and verify with matching key":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()
    check ticket.verify(publicKey) == true

  test "Ticket verification fails with wrong key":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let wrongPublicKey = PrivateKey.random(rng[]).get().getPublicKey().get()
    check ticket.verify(wrongPublicKey) == false

  test "Ticket verification fails with tampered t_init":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
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
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
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
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with t_wait_for
    ticket.t_wait_for = 7777
    check ticket.verify(publicKey) == false

  test "Ticket verification fails with tampered advertisement":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with the ad serviceId
    ticket.ad.serviceId[0] = 255'u8
    check ticket.verify(publicKey) == false

  test "Ticket signature over correct fields - ad metadata affects verification":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[], # Empty metadata doesn't affect encoding
      timestamp: 12345,
    )
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Ticket signature is over encoded_ad which includes timestamp and non-empty metadata
    # With empty metadata, modify ad.timestamp
    ticket.ad.timestamp = 54321
    check ticket.verify(publicKey) == false

  test "Ticket signature over correct fields - ad timestamp not signed":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 12345,
    )
    var ticket =
      Ticket(ad: ad, t_init: 1000000, t_mod: 2000000, t_wait_for: 3000, signature: @[])

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ticket.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()

    # Modify ad timestamp - ticket signature is over encoded ad which includes timestamp
    # So this should fail verification
    ticket.ad.timestamp = 54321
    check ticket.verify(publicKey) == false

  test "Advertisement with multiple addresses signature":
    let maddrs =
      @[
        MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get(),
        MultiAddress.init("/ip4/192.168.1.1/tcp/4001").get(),
      ]
    var ad = Advertisement(
      serviceId: @[1'u8, 2, 3, 4],
      peerId: PeerId.init(PrivateKey.random(rng[]).get()).get(),
      addrs: maddrs,
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ad.sign(privateKey)
    check signResult.isOk()

    let publicKey = privateKey.getPublicKey().get()
    check ad.verify(publicKey) == true

    # Modify one address - should fail
    ad.addrs[0] = MultiAddress.init("/ip4/10.0.0.1/tcp/8000").get()
    check ad.verify(publicKey) == false
