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
