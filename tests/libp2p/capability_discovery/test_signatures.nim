# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import results
import ../../../libp2p/[peerid, crypto/crypto, multiaddress]
import ../../../libp2p/protocols/capability_discovery/types
import ../../../libp2p/protocols/kademlia/protobuf
import ../../tools/[unittest, crypto]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# ===========================================================================
# Unit tests
# ===========================================================================

suite "Ticket - sign and verify":
  test "sign succeeds and verify passes with matching key":
    let key = PrivateKey.random(rng[]).get()
    var t = makeTicket()

    check t.sign(key).isOk()
    check t.verify(key.getPublicKey().get())

  test "verify fails with a different key":
    let key = PrivateKey.random(rng[]).get()
    let wrongKey = PrivateKey.random(rng[]).get()
    let t = signedTicket(key)

    check not t.verify(wrongKey.getPublicKey().get())

  test "verify fails on empty signature (unsigned ticket)":
    let key = PrivateKey.random(rng[]).get()
    let t = makeTicket() # never signed → signature = @[]

    check not t.verify(key.getPublicKey().get())

  test "verify fails with corrupted signature bytes":
    let key = PrivateKey.random(rng[]).get()
    var t = signedTicket(key)
    t.signature[0] = t.signature[0] xor 0xFF

    check not t.verify(key.getPublicKey().get())

suite "Ticket - tamper detection":
  # The signature covers: advertisement || tInit || tMod || tWaitFor
  # Mutating any covered field must break verification.

  test "tampered advertisement bytes":
    let key = PrivateKey.random(rng[]).get()
    var t = signedTicket(key)
    t.advertisement[0] = t.advertisement[0] xor 0xFF

    check not t.verify(key.getPublicKey().get())

  test "tampered tInit":
    let key = PrivateKey.random(rng[]).get()
    var t = signedTicket(key)
    t.tInit = t.tInit + 1

    check not t.verify(key.getPublicKey().get())

  test "tampered tMod":
    let key = PrivateKey.random(rng[]).get()
    var t = signedTicket(key)
    t.tMod = t.tMod + 1

    check not t.verify(key.getPublicKey().get())

  test "tampered tWaitFor":
    let key = PrivateKey.random(rng[]).get()
    var t = signedTicket(key)
    t.tWaitFor = t.tWaitFor + 1

    check not t.verify(key.getPublicKey().get())

suite "Ticket - boundary values":
  test "all-zero time fields sign and verify correctly":
    # tInit=0, tMod=0, tWaitFor=0 are valid; must not be treated as unsigned
    let key = PrivateKey.random(rng[]).get()
    var t =
      Ticket(advertisement: @[0xAB'u8], tInit: 0, tMod: 0, tWaitFor: 0, signature: @[])

    check t.sign(key).isOk()
    check t.verify(key.getPublicKey().get())

  test "empty advertisement bytes sign and verify correctly":
    let key = PrivateKey.random(rng[]).get()
    var t = Ticket(
      advertisement: @[],
      tInit: 1000,
      tMod: 2000,
      tWaitFor: 300,
      signature: @[],
    )

    check t.sign(key).isOk()
    check t.verify(key.getPublicKey().get())

  test "re-signing overwrites previous signature":
    # Signing twice must not leave a ticket that verifies against the first key
    let key1 = PrivateKey.random(rng[]).get()
    let key2 = PrivateKey.random(rng[]).get()
    var t = makeTicket()

    discard t.sign(key1)
    discard t.sign(key2) # overwrite

    check not t.verify(key1.getPublicKey().get())
    check t.verify(key2.getPublicKey().get())
