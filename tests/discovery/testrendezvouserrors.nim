{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import sequtils
import strformat
import strutils
import chronos
import
  ../../libp2p/[
    protocols/rendezvous,
    protocols/rendezvous/protobuf,
    peerinfo,
    switch,
    routing_record,
    crypto/crypto,
  ]
import ../../libp2p/discovery/discoverymngr
import ../helpers
import ./utils

suite "RendezVous Errors":
  teardown:
    checkTrackers()

  asyncTest "Various local error":
    let rdv = RendezVous.new(minDuration = 1.minutes, maxDuration = 72.hours)
    expect AdvertiseError:
      discard await rdv.request(Opt.some("A".repeat(300)))
    expect AdvertiseError:
      discard await rdv.request(Opt.some("A"), -1)
    expect AdvertiseError:
      discard await rdv.request(Opt.some("A"), 3000)
    expect AdvertiseError:
      await rdv.advertise("A".repeat(300))
    expect AdvertiseError:
      await rdv.advertise("A", 73.hours)
    expect AdvertiseError:
      await rdv.advertise("A", 30.seconds)

  test "Various config error":
    expect RendezVousError:
      discard RendezVous.new(minDuration = 30.seconds)
    expect RendezVousError:
      discard RendezVous.new(maxDuration = 73.hours)
    expect RendezVousError:
      discard RendezVous.new(minDuration = 15.minutes, maxDuration = 10.minutes)

  let testCases =
    @[
      (
        "Register - Invalid Namespace",
        (
          proc(node: RendezVous): Message =
            prepareRegisterMessage(
              "A".repeat(300),
              node.switch.peerInfo.signedPeerRecord.encode().get,
              2.hours,
            )
        ),
        ResponseStatus.InvalidNamespace,
      ),
      (
        "Register - Invalid Signed Peer Record",
        (
          proc(node: RendezVous): Message =
            # Malformed SPR - empty bytes will fail validation
            prepareRegisterMessage("namespace", newSeq[byte](), 2.hours)
        ),
        ResponseStatus.InvalidSignedPeerRecord,
      ),
      (
        "Register - Invalid TTL",
        (
          proc(node: RendezVous): Message =
            prepareRegisterMessage(
              "namespace", node.switch.peerInfo.signedPeerRecord.encode().get, 73.hours
            )
        ),
        ResponseStatus.InvalidTTL,
      ),
      (
        "Discover - Invalid Namespace",
        (
          proc(node: RendezVous): Message =
            prepareDiscoverMessage(ns = Opt.some("A".repeat(300)))
        ),
        ResponseStatus.InvalidNamespace,
      ),
      (
        "Discover - Invalid Cookie",
        (
          proc(node: RendezVous): Message =
            # Empty buffer will fail Cookie.decode().tryGet() and yield InvalidCookie
            prepareDiscoverMessage(cookie = Opt.some(newSeq[byte]()))
        ),
        ResponseStatus.InvalidCookie,
      ),
    ]

  for test in testCases:
    let (testName, getMessage, expectedStatus) = test

    asyncTest &"Node returns ERROR_CODE for invalid message - {testName}":
      let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
      (rendezvousNode & peerNodes).startAndDeferStop()

      await connectNodes(peerNodes[0], rendezvousNode)

      let
        peerNode = peerNodes[0]
        messageBuf = encode(getMessage(peerNode)).buffer

      let
        responseBuf = await sendRdvMessage(peerNode, rendezvousNode, messageBuf)
        responseMessage = Message.decode(responseBuf).tryGet()
        actualStatus =
          if responseMessage.registerResponse.isSome():
            responseMessage.registerResponse.get.status
          else:
            responseMessage.discoverResponse.get.status

      check actualStatus == expectedStatus

  asyncTest "Node returns NotAuthorized when Register exceeding peer limit":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    # Pre-populate registrations up to the limit for this peer under the same namespace
    let namespace = "namespaceNA"
    await populatePeerRegistrations(
      peerNodes[0], rendezvousNode, namespace, RegistrationLimitPerPeer
    )

    # Attempt one more registration which should be rejected with NotAuthorized
    let messageBuf = encode(
      prepareRegisterMessage(
        namespace, peerNodes[0].switch.peerInfo.signedPeerRecord.encode().get, 2.hours
      )
    ).buffer

    let responseBuf = await sendRdvMessage(peerNodes[0], rendezvousNode, messageBuf)
    let responseMessage = Message.decode(responseBuf).tryGet()
    check responseMessage.registerResponse.get.status == ResponseStatus.NotAuthorized
