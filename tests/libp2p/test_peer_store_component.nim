# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sequtils
import chronos
import ../../libp2p/[peerstore, peerinfo, multiaddress, switch, protocols/kademlia]
import ../tools/[unittest, multiaddress, switch_builder, lifecycle, topology]
import ./kademlia/utils

suite "PeerStore Address TTL - Component":
  teardown:
    checkTrackers()

  asyncTest "identify stores peer addresses at Medium confidence":
    let
      listener = makeStandardSwitch(TcpAutoAddress)
      dialer = makeStandardSwitch(TcpAutoAddress)
    startAndDeferStop(@[listener, dialer])

    await dialer.connect(listener.peerInfo.peerId, listener.peerInfo.addrs)

    # The listener only accepts the connection, so identify is its only source for the dialer's addresses.
    # The listener never dials the dialer, so nothing upgrades it to High.
    checkUntilTimeout:
      listener.peerStore[AddressBook].entries(dialer.peerInfo.peerId).len > 0
      listener.peerStore[AddressBook].entries(dialer.peerInfo.peerId).allIt(
        it.confidence == AddressConfidence.Medium
      )

  asyncTest "successful dial records address at High confidence":
    let
      listener = makeStandardSwitch(TcpAutoAddress)
      dialer = makeStandardSwitch(TcpAutoAddress)
    startAndDeferStop(@[listener, dialer])

    await dialer.connect(listener.peerInfo.peerId, listener.peerInfo.addrs)

    # A successful dial marks the dialed address High.
    checkUntilTimeout:
      dialer.peerStore[AddressBook].entries(listener.peerInfo.peerId).anyIt(
        it.confidence == AddressConfidence.High
      )

  asyncTest "kademlia discovery stores discovered addresses at Low confidence":
    # kads[0] is a hub that knows both others.
    # kads[1] and kads[2] are not directly connected, so kads[1] can only learn
    # kads[2] through a DHT lookup.
    let kads = setupKadSwitches(3)
    startAndDeferStop(kads)
    await connectHub(kads[0], kads[1 ..^ 1])

    check kads[2].switch.peerInfo.peerId notin kads[1].switch.peerStore[AddressBook]

    # Stop kads[2] so the lookup cannot dial it.
    await kads[2].switch.stop()

    # kads[1] discovers kads[2] through kads[0]'s FIND_NODE response.
    discard await kads[1].findNode(kads[2].rtable.selfId)

    # The addresses arrive in a DHT response, so they are stored at the Low confidence.
    let entries =
      kads[1].switch.peerStore[AddressBook].entries(kads[2].switch.peerInfo.peerId)
    check:
      entries.len == 1
      entries[0].confidence == AddressConfidence.Low

  asyncTest "later identify update does not downgrade a verified High address":
    let
      listener = makeStandardSwitch(TcpAutoAddress)
      dialer = makeStandardSwitch(TcpAutoAddress)
    startAndDeferStop(@[listener, dialer])

    await dialer.connect(listener.peerInfo.peerId, listener.peerInfo.addrs)

    # Wait for the dialed address to reach High before the update.
    checkUntilTimeout:
      dialer.peerStore[AddressBook].entries(listener.peerInfo.peerId).anyIt(
        it.confidence == AddressConfidence.High
      )

    # The listener announces an extra address.
    # Its IdentifyPusher pushes the updated PeerInfo to the dialer at Medium.
    let extra = ma("/ip4/127.0.0.1/tcp/4099")
    listener.peerInfo.listenAddrs.add(extra)
    await listener.peerInfo.update()

    # The extra address is stored at Medium.
    # The already dialed address stays High.
    checkUntilTimeout:
      dialer.peerStore[AddressBook].entries(listener.peerInfo.peerId).anyIt(
        it.address == extra and it.confidence == AddressConfidence.Medium
      )
      dialer.peerStore[AddressBook].entries(listener.peerInfo.peerId).anyIt(
        it.confidence == AddressConfidence.High
      )
