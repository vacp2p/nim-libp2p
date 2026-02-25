# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

# Thread Request Example Implementation
#
# This file defines the `LifecycleRequest` type and its lifecycle, including memory
# management and request processing. This structure is used for communicating with the
# main thread, which is the one that runs LibP2P

import std/[json, tables]
import chronos, results

import ../../../[types, ffi_types, alloc]
import ../../../../libp2p
import ../../../../libp2p/[multiaddress, peerid]
import ../../../../libp2p/crypto/secp
import ../../../../libp2p/nameresolving/[dnsresolver, nameresolver]
import ../../../../libp2p/protocols/pubsub/gossipsub
import ../../../../libp2p/protocols/kademlia
import ../../../../libp2p/protocols/kademlia_discovery/types
import ../../../../libp2p/protocols/ping
import ../../../../libp2p/protocols/mix
import ../../../../libp2p/protocols/mix/mix_protocol
import ../../../../libp2p/protocols/mix/mix_node

const DefaultDnsResolver = "1.1.1.1:53"

type LifecycleMsgType* = enum
  CREATE_LIBP2P
  START_NODE
  STOP_NODE
  GET_PUBLIC_KEY

type LifecycleRequest* = object
  operation*: LifecycleMsgType
  appCallbacks: AppCallbacks
  config: Libp2pConfig

proc parseBootstrapNodes(config: Libp2pConfig): seq[(PeerId, seq[MultiAddress])] =
  if config.kadBootstrapNodesLen == 0:
    return @[]

  if config.kadBootstrapNodes.isNil():
    raiseAssert "kad bootstrap nodes are missing"

  var response: seq[(PeerId, seq[MultiAddress])]
  let nodes = cast[ptr UncheckedArray[Libp2pBootstrapNode]](config.kadBootstrapNodes)
  for i in 0 ..< config.kadBootstrapNodesLen:
    if nodes[i].peerId.isNil():
      raiseAssert "missing bootstrap peer id"

    let peerIdStr = $nodes[i].peerId
    let peerId = PeerId.init(peerIdStr).valueOr:
      raiseAssert "invalid bootstrap peer id: " & $error

    var addrs: seq[MultiAddress]
    if nodes[i].multiaddrsLen > 0:
      if nodes[i].multiaddrs.isNil():
        raiseAssert "missing bootstrap multiaddrs for " & peerIdStr

      let addrsArr = cast[ptr UncheckedArray[cstring]](nodes[i].multiaddrs)
      for j in 0 ..< nodes[i].multiaddrsLen:
        if addrsArr[j].isNil():
          raiseAssert "bootstrap multiaddr is nil for " & peerIdStr
        let addrStr = $addrsArr[j]
        let ma = MultiAddress.init(addrStr).valueOr:
          raiseAssert "invalid bootstrap multiaddr: " & $error
        addrs.add(ma)

    response.add((peerId, addrs))

  return response

proc toByteSeq(key: Libp2pPrivateKey): seq[byte] =
  if key.dataLen == 0 or key.data.isNil():
    return newSeq[byte](0)
  let data = newSeqUninit[byte](key.dataLen.int)
  copyMem(addr data[0], key.data, key.dataLen)
  return data

proc mountGossipsub(libp2p: var LibP2P, config: Libp2pConfig) =
  var gossipSub = Opt.none(GossipSub)
  if config.mountGossipsub != 0:
    let gs = GossipSub.init(
      switch = libp2p.switch, triggerSelf = config.gossipsubTriggerSelf != 0
    )
    libp2p.switch.mount(gs)
    gossipSub = Opt.some(gs)
  libp2p.gossipSub = gossipSub

proc mountKad(libp2p: var LibP2P, config: Libp2pConfig) =
  var kad = Opt.none(KadDHT)
  if config.mountKad != 0 or config.mountKadDiscovery != 0:
    let bootstrapNodes = parseBootstrapNodes(config)
    if config.mountKadDiscovery != 0:
      let k = KademliaDiscovery.new(
        libp2p.switch,
        bootstrapNodes = bootstrapNodes,
        codec = ExtendedKademliaDiscoveryCodec,
      )
      libp2p.switch.mount(k)
      kad = Opt.some(KadDHT(k))
    else:
      let k = KadDHT.new(libp2p.switch, bootstrapNodes = bootstrapNodes)
      libp2p.switch.mount(k)
      kad = Opt.some(k)
  libp2p.kad = kad

proc mountMix(libp2p: var LibP2P, config: Libp2pConfig) =
  var mix = Opt.none(MixProtocol)
  if config.mountMix != 0 and libp2p.mixNodeInfo.isSome:
    var mixProto = new(MixProtocol)
    var delayStrategy = NoSamplingDelayStrategy.new(newRng())
    mixProto.init(
      libp2p.mixNodeInfo.get(), libp2p.switch, delayStrategy = delayStrategy
    )
    libp2p.switch.mount(mixProto)
    mix = Opt.some(mixProto)
  libp2p.mix = mix

proc mountProtocols(libp2p: var LibP2P, config: Libp2pConfig) =
  if config.mountGossipsub != 0:
    libp2p.mountGossipsub(config)
  if config.mountKad != 0 or config.mountKadDiscovery != 0:
    libp2p.mountKad(config)

  libp2p.switch.mount(Ping.new())

  libp2p.mountMix(config)

proc createLibp2p(appCallbacks: AppCallbacks, config: Libp2pConfig): LibP2P =
  let dnsResolver =
    Opt.some(cast[NameResolver](DnsResolver.new(@[initTAddress($config.dnsResolver)])))

  var privKey = Opt.none(PrivateKey)
  if config.privKey.data != nil and config.privKey.dataLen > 0:
    let keySeq = config.privKey.toByteSeq()
    PrivateKey.init(keySeq).withValue(copyKey):
      privKey = Opt.some(copyKey)

  let switch = newStandardSwitch(privKey = privKey, nameResolver = dnsResolver)

  var ret = LibP2P(
    switch: switch,
    gossipSub: Opt.none(GossipSub),
    kad: Opt.none(KadDHT),
    mix: Opt.none(MixProtocol),
    mixNodeInfo: Opt.none(MixNodeInfo),
    topicHandlers: initTable[PubsubTopicPair, TopicHandlerEntry](),
    connections: initTable[ptr Libp2pStream, Connection](),
  )

  mountProtocols(ret, config)

  return ret

proc init*(T: typedesc[Libp2pConfig]): T =
  T(
    mountGossipsub: 1,
    gossipsubTriggerSelf: 1,
    mountKad: 1,
    mountMix: 0,
    mountKadDiscovery: 0,
    dnsResolver: DefaultDnsResolver.alloc(),
    kadBootstrapNodes: nil,
    kadBootstrapNodesLen: 0,
  )

proc copyConfig(config: ptr Libp2pConfig): Libp2pConfig =
  var resolved = Libp2pConfig.default()

  if config.isNil():
    return resolved

  resolved.mountGossipsub = config[].mountGossipsub
  resolved.gossipsubTriggerSelf = config[].gossipsubTriggerSelf
  resolved.mountKad = config[].mountKad
  resolved.mountMix = config[].mountMix
  resolved.mountKadDiscovery = config[].mountKadDiscovery

  if not config[].dnsResolver.isNil() and config[].dnsResolver[0] != '\0':
    let src = config[].dnsResolver
    var len = 0
    while src[len] != '\0':
      inc len
    inc len # include null terminator

    resolved.dnsResolver = cast[cstring](allocShared(len))
    copyMem(resolved.dnsResolver, src, len)

  if not config[].privKey.data.isNil() and config[].privKey.dataLen > 0:
    let srcKey = config[].privKey
    resolved.privKey.dataLen = srcKey.dataLen
    resolved.privKey.data = allocShared(srcKey.dataLen.int)
    copyMem(resolved.privKey.data, srcKey.data, srcKey.dataLen.int)

  resolved.kadBootstrapNodesLen = config[].kadBootstrapNodesLen
  if not config[].kadBootstrapNodes.isNil() and config[].kadBootstrapNodesLen > 0:
    resolved.kadBootstrapNodes = cast[ptr Libp2pBootstrapNode](allocShared(
      sizeof(Libp2pBootstrapNode) * config[].kadBootstrapNodesLen.int
    ))
    let src = cast[ptr UncheckedArray[Libp2pBootstrapNode]](config[].kadBootstrapNodes)
    let dst = cast[ptr UncheckedArray[Libp2pBootstrapNode]](resolved.kadBootstrapNodes)
    for i in 0 ..< config[].kadBootstrapNodesLen:
      dst[i].peerId = src[i].peerId.alloc()
      dst[i].multiaddrsLen = src[i].multiaddrsLen
      if dst[i].multiaddrsLen == 0 or src[i].multiaddrs.isNil():
        dst[i].multiaddrs = nil
      else:
        dst[i].multiaddrs =
          allocCStringArrayFromCArray(src[i].multiaddrs, src[i].multiaddrsLen)

  resolved

proc createShared*(
    T: type LifecycleRequest,
    op: LifecycleMsgType,
    appCallbacks: AppCallbacks = nil,
    config: ptr Libp2pConfig = nil,
): ptr type T =
  # TODO: Modify for your request's specific field initialization
  # TODO: Allocate parameters of GC'd types to the shared memory
  var ret = createShared(T)
  ret[].operation = op
  ret[].appCallbacks = appCallbacks
  ret[].config = copyConfig(config)

  return ret

proc destroyShared(self: ptr LifecycleRequest) =
  # TODO: Free any newly added fields here if you change the object structure
  # TODO: Deallocate parameters of GC'd types from the shared memory
  if not self[].config.dnsResolver.isNil():
    deallocShared(self[].config.dnsResolver)
  if not self[].config.kadBootstrapNodes.isNil():
    let nodes =
      cast[ptr UncheckedArray[Libp2pBootstrapNode]](self[].config.kadBootstrapNodes)
    for i in 0 ..< self[].config.kadBootstrapNodesLen:
      if not nodes[i].peerId.isNil():
        deallocShared(nodes[i].peerId)
      deallocCStringArray(nodes[i].multiaddrs, nodes[i].multiaddrsLen)
    deallocShared(self[].config.kadBootstrapNodes)
  if not self[].config.privKey.data.isNil():
    deallocShared(self[].config.privKey.data)
  deallocShared(self)

proc processGetPublicKey*(
    self: ptr LifecycleRequest, libp2p: ptr LibP2P
): Future[Result[ptr ReadResponse, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let peerInfo = libp2p[].switch.peerInfo
  if peerInfo.isNil():
    return err("switch peerInfo is nil")

  let pubKey =
    case peerInfo.publicKey.scheme
    of PKScheme.Secp256k1:
      peerInfo.publicKey.skkey
    else:
      return err("peerInfo public key must be secp256k1")

  return ok(allocReadResponse(pubKey.getBytes()))

proc process*(
    self: ptr LifecycleRequest, libp2p: ptr LibP2P
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_LIBP2P:
    try:
      libp2p[] = createLibp2p(self.appCallbacks, self.config)
    except TransportAddressError as exc:
      return err("could not create libp2p node: " & $exc.msg)
    except LPError as exc:
      return err("could not create libp2p node: " & $exc.msg)
    except OSError as exc:
      return err("could not create libp2p node: " & exc.msg)
    except IOError as exc:
      return err("could not create libp2p node: " & exc.msg)
  of START_NODE:
    try:
      await libp2p.switch.start()
    except LPError:
      return err(getCurrentExceptionMsg())
  of STOP_NODE:
    await libp2p.switch.stop()
  else:
    raiseAssert "unsupported operation"

  return ok()
