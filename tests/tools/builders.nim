
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import results, chronos 
import
  ../../libp2p/[
    errors,
    dial,
    switch,
    multistream,
    builders,
    stream/bufferstream,
    stream/connection,
    multicodec,
    multiaddress,
    peerinfo,
    crypto/crypto,
    protocols/protocol,
    protocols/secure/secure,
    muxers/muxer,
    muxers/mplex/lpchannel,
    stream/lpstream,
    nameresolving/mockresolver,
    nameresolving/nameresolver,
    stream/chronosstream,
    transports/tcptransport,
    transports/wstransport,
    transports/quictransport,
  ]

type TransportType* {.pure.} = enum
  QUIC
  TCP
  Memory

type MuxerType* {.pure.} = enum
  MPLEX
  YAMUX

proc newStandardSwitchBuilder*(
    rng: Rng,
    privKey = Opt.none(PrivateKey),
    addrs: MultiAddress | seq[MultiAddress] = newSeq[MultiAddress](),
    transport: TransportType = TransportType.TCP,
    transportFlags: set[ServerFlags] = {},
    muxer: MuxerType = MuxerType.MPLEX,
    secureManagers: openArray[SecureProtocol] = [SecureProtocol.Noise],
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes,
    connectionLimits: Opt[ConnectionLimits] = Opt.none(ConnectionLimits),
    maxConnsPerPeer = -1,
    nameResolver = Opt.none(NameResolver),
    sendSignedPeerRecord = false,
    peerStoreCapacity = 1000,
): SwitchBuilder {.raises: [LPError].} =
  ## Helper for common switch configurations.
  var b = SwitchBuilder
    .new()
    .withRng(rng)
    .withSignedPeerRecord(sendSignedPeerRecord)
    .withPeerStore(capacity = peerStoreCapacity)
    .withNoise()

  connectionLimits.withValue(cfg):
    b = b.withConnectionLimits(cfg)

  if maxConnsPerPeer > 0:
    b = b.withMaxConnsPerPeer(maxConnsPerPeer)

  privKey.withValue(pkey):
    b = b.withPrivateKey(pkey)

  nameResolver.withValue(nr):
    b = b.withNameResolver(nr)

  var addrs =
    when addrs is MultiAddress:
      @[addrs]
    else:
      addrs

  case transport
  of TransportType.QUIC:
    if addrs.len == 0:
      addrs = @[MultiAddress.init("/ip4/0.0.0.0/udp/0/quic-v1").tryGet()]
    b = b.withQuicTransport().withAddresses(addrs)
    return b # quic does not use a muxer
  of TransportType.TCP:
    if addrs.len == 0:
      addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()]
    b = b.withTcpTransport(transportFlags).withAddresses(addrs)
  of TransportType.Memory:
    if addrs.len == 0:
      addrs = @[MultiAddress.init(MemoryAutoAddress).tryGet()]
    b = b.withMemoryTransport().withAddresses(addrs)

  case muxer
  of MuxerType.MPLEX:
    b = b.withMplex(inTimeout, outTimeout)
  of MuxerType.YAMUX:
    b = b.withYamux(inTimeout = inTimeout, outTimeout = outTimeout)

  b

proc newStandardSwitch*(
    rng: Rng,
    privKey = Opt.none(PrivateKey),
    addrs: MultiAddress | seq[MultiAddress] = newSeq[MultiAddress](),
    transport: TransportType = TransportType.TCP,
    transportFlags: set[ServerFlags] = {},
    muxer: MuxerType = MuxerType.MPLEX,
    secureManagers: openArray[SecureProtocol] = [SecureProtocol.Noise],
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes,
    connectionLimits: Opt[ConnectionLimits] = Opt.none(ConnectionLimits),
    maxConnsPerPeer = -1,
    nameResolver = Opt.none(NameResolver),
    sendSignedPeerRecord = false,
    peerStoreCapacity = 1000,
): Switch {.raises: [LPError].} =
  newStandardSwitchBuilder(
    rng = rng,
    privKey = privKey,
    addrs = addrs,
    transport = transport,
    transportFlags = transportFlags,
    muxer = muxer,
    secureManagers = secureManagers,
    inTimeout = inTimeout,
    outTimeout = outTimeout,
    connectionLimits = connectionLimits,
    maxConnsPerPeer = maxConnsPerPeer,
    nameResolver = nameResolver,
    sendSignedPeerRecord = sendSignedPeerRecord,
    peerStoreCapacity = peerStoreCapacity,
  )
    .build()
