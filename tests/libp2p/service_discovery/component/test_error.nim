# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results
import
  ../../../../libp2p/[
    protobuf/minprotobuf,
    protocols/service_discovery/advertiser,
    protocols/service_discovery/types,
    stream/connection,
    switch,
  ]
from ../../../../libp2p/protocols/kademlia/types import MaxMsgSize
import ../../../../libp2p/protocols/kademlia/protobuf as kad_protobuf
import ../../../tools/[lifecycle, unittest]
import ../utils

proc sendRawMessage(
    clientSwitch: Switch, registrarNode: ServiceDiscovery, msgBytes: seq[byte]
): Future[seq[byte]] {.async.} =
  let conn = await clientSwitch.dial(
    registrarNode.switch.peerInfo.peerId, registrarNode.switch.peerInfo.addrs,
    ExtendedServiceDiscoveryCodec,
  )
  defer:
    await conn.close()

  await conn.writeLp(msgBytes)

  return await conn.readLp(MaxMsgSize)

proc sendMessage(
    clientNode, registrarNode: ServiceDiscovery, msg: kad_protobuf.Message
): Future[kad_protobuf.Message] {.async.} =
  let responseBytes =
    await clientNode.switch.sendRawMessage(registrarNode, msg.encode().buffer)
  let response = kad_protobuf.Message.decode(responseBytes)
  check response.isOk()
  return response.get()

suite "Service Discovery Component - Error Handling":
  teardown:
    checkTrackers()

  asyncTest "message with unknown MessageType is rejected without a reply":
    let registrarNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode])

    let clientSwitch = createSwitch()
    await clientSwitch.start()
    defer:
      await clientSwitch.stop()

    # msgType = 99 is outside the MessageType enum, so decodeEnum will reject it.
    var pb = initProtoBuffer()
    pb.write(1, 99'u32)
    pb.finish()
    let invalidMsg = pb.buffer

    expect LPStreamError:
      discard
        await clientSwitch.sendRawMessage(registrarNode, invalidMsg).wait(2.seconds)

  asyncTest "REGISTER without register body returns Rejected":
    let registrarNode = setupServiceDiscoveryNode()
    let clientNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, clientNode])
    await connect(registrarNode, clientNode)

    let serviceId = makeServiceId()
    let msg = kad_protobuf.Message(
      msgType: kad_protobuf.MessageType.register,
      key: serviceId,
      register: Opt.none(kad_protobuf.RegisterMessage),
    )

    let response = await clientNode.sendMessage(registrarNode, msg)
    check:
      response.register.get().status.get() == kad_protobuf.RegistrationStatus.Rejected
      registrarNode.countAdsInCache(serviceId) == 0

  asyncTest "REGISTER with empty advertisement returns Rejected":
    let registrarNode = setupServiceDiscoveryNode()
    let clientNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, clientNode])
    await connect(registrarNode, clientNode)

    let serviceId = makeServiceId()
    let msg = kad_protobuf.Message(
      msgType: kad_protobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kad_protobuf.RegisterMessage(
          advertisement: @[],
          status: Opt.none(kad_protobuf.RegistrationStatus),
          ticket: Opt.none(kad_protobuf.Ticket),
        )
      ),
    )

    let response = await clientNode.sendMessage(registrarNode, msg)
    check:
      response.register.get().status.get() == kad_protobuf.RegistrationStatus.Rejected
      registrarNode.countAdsInCache(serviceId) == 0

  asyncTest "REGISTER with malformed advertisement bytes returns Rejected":
    let registrarNode = setupServiceDiscoveryNode()
    let advertiserNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceId = makeServiceId()
    let adBytes = @[1'u8, 2, 3, 4]

    let regResp = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    require regResp.isOk()
    check:
      regResp.get().status == kad_protobuf.RegistrationStatus.Rejected
      registrarNode.countAdsInCache(serviceId) == 0

  asyncTest "REGISTER with advertisement for another service returns Rejected":
    let registrarNode = setupServiceDiscoveryNode()
    let clientNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, clientNode])
    await connect(registrarNode, clientNode)

    let serviceId = "service".hashServiceId()
    let adBytes = makeAdvertisement(
        "other-service", clientNode.switch.peerInfo.privateKey
      )
      .encode()
      .get()
    let msg = kad_protobuf.Message(
      msgType: kad_protobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kad_protobuf.RegisterMessage(
          advertisement: adBytes,
          status: Opt.none(kad_protobuf.RegistrationStatus),
          ticket: Opt.none(kad_protobuf.Ticket),
        )
      ),
    )

    let response = await clientNode.sendMessage(registrarNode, msg)
    check:
      response.register.get().status.get() == kad_protobuf.RegistrationStatus.Rejected
      registrarNode.countAdsInCache(serviceId) == 0

  asyncTest "oversized message is rejected without a reply":
    let registrarNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode])

    let clientSwitch = createSwitch()
    await clientSwitch.start()
    defer:
      await clientSwitch.stop()

    let oversizedMsg = newSeq[byte](MaxMsgSize + 1)

    expect LPStreamError:
      discard
        await clientSwitch.sendRawMessage(registrarNode, oversizedMsg).wait(2.seconds)

  asyncTest "REGISTER with non-32-byte key returns Rejected":
    # Spec calls for rejection on bad key length.
    # Impl has no length check, the key reaches the service-membership check.
    let registrarNode = setupServiceDiscoveryNode()
    let clientNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, clientNode])
    await connect(registrarNode, clientNode)

    let adBytes =
      makeAdvertisement("service", clientNode.switch.peerInfo.privateKey).encode().get()

    for keyLen in [0, 31, 33, 64]:
      let key = newSeq[byte](keyLen)

      let msg = kad_protobuf.Message(
        msgType: kad_protobuf.MessageType.register,
        key: key,
        register: Opt.some(
          kad_protobuf.RegisterMessage(
            advertisement: adBytes,
            status: Opt.none(kad_protobuf.RegistrationStatus),
            ticket: Opt.none(kad_protobuf.Ticket),
          )
        ),
      )

      let response = await clientNode.sendMessage(registrarNode, msg)
      check:
        response.register.get().status.get() == kad_protobuf.RegistrationStatus.Rejected
        registrarNode.countAdsInCache(key) == 0

  asyncTest "REGISTER with ticket that has mismatched advertisement returns Rejected":
    # A ticket whose embedded advertisement does not match the registration's
    # advertisement must be rejected (prevents tInit poisoning via unsigned tickets).
    let registrarNode = setupServiceDiscoveryNode()
    let clientNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, clientNode])
    await connect(registrarNode, clientNode)

    let serviceId = "service".hashServiceId()
    let adBytes =
      makeAdvertisement("service", clientNode.switch.peerInfo.privateKey).encode().get()
    let otherAdBytes =
      makeAdvertisement("other", clientNode.switch.peerInfo.privateKey).encode().get()

    var badTicket = kad_protobuf.Ticket(
      advertisement: otherAdBytes,
      tInit: Moment.now() - 10.secs,
      tMod: Moment.now() - 5.secs,
      tWaitFor: 1.secs,
      signature: @[],
    )
    check badTicket.sign(registrarNode.switch.peerInfo.privateKey).isOk()

    let msg = kad_protobuf.Message(
      msgType: kad_protobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kad_protobuf.RegisterMessage(
          advertisement: adBytes,
          status: Opt.none(kad_protobuf.RegistrationStatus),
          ticket: Opt.some(badTicket),
        )
      ),
    )

    let response = await clientNode.sendMessage(registrarNode, msg)
    check:
      response.register.get().status.get() == kad_protobuf.RegistrationStatus.Rejected
      registrarNode.countAdsInCache(serviceId) == 0

  asyncTest "REGISTER with ticket that has invalid signature returns Rejected":
    # A ticket that fails signature verification (wrong key or tampered) must
    # produce Rejected; its time values must never be trusted or copied.
    let registrarNode = setupServiceDiscoveryNode()
    let clientNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, clientNode])
    await connect(registrarNode, clientNode)

    let serviceId = "service".hashServiceId()
    let adBytes =
      makeAdvertisement("service", clientNode.switch.peerInfo.privateKey).encode().get()

    # Sign with a different node's key
    let otherNode = setupServiceDiscoveryNode()
    var badTicket = kad_protobuf.Ticket(
      advertisement: adBytes,
      tInit: Moment.now() - 1000.secs,
      tMod: Moment.now() - 500.secs,
      tWaitFor: 10.secs,
      signature: @[],
    )
    check badTicket.sign(otherNode.switch.peerInfo.privateKey).isOk()

    let msg = kad_protobuf.Message(
      msgType: kad_protobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kad_protobuf.RegisterMessage(
          advertisement: adBytes,
          status: Opt.none(kad_protobuf.RegistrationStatus),
          ticket: Opt.some(badTicket),
        )
      ),
    )

    let response = await clientNode.sendMessage(registrarNode, msg)
    check:
      response.register.get().status.get() == kad_protobuf.RegistrationStatus.Rejected
      registrarNode.countAdsInCache(serviceId) == 0

  asyncTest "GET_ADS with non-32-byte key returns empty response":
    # Spec calls for rejection on bad key length.
    # Impl has no length check, cache lookup misses on the arbitrary key.
    let registrarNode = setupServiceDiscoveryNode()
    let clientNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, clientNode])
    await connect(registrarNode, clientNode)

    for keyLen in [0, 31, 33, 64]:
      let key = newSeq[byte](keyLen)

      let msg = kad_protobuf.Message(msgType: kad_protobuf.MessageType.getAds, key: key)

      let response = await clientNode.sendMessage(registrarNode, msg)
      check:
        response.msgType == kad_protobuf.MessageType.getAds
        response.getAds.isSome()
        response.getAds.get().advertisements.len == 0
