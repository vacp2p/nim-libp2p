# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sequtils
import chronos
import
  ../../libp2p/
    [addressmanager, crypto/crypto, multiaddress, multicodec, peerinfo, switch]
import ../../libp2p/services/natservice
import ../tools/[unittest, crypto, switch_builder, multiaddress]

proc newManager(
    maxSize = DefaultObservedAddrMaxSize,
    minCount = DefaultObservedAddrMinCount,
    candidateTtl = DefaultCandidateTtl,
): AddressManager =
  AddressManager.new(
    AddressManagerConfig(
      maxSize: maxSize, minCount: minCount, candidateTtl: candidateTtl
    )
  )

proc newStartedManager(
    maxSize = DefaultObservedAddrMaxSize,
    minCount = DefaultObservedAddrMinCount,
    candidateTtl = DefaultCandidateTtl,
): AddressManager =
  let manager = newManager(maxSize, minCount, candidateTtl)
  manager.start()
  manager

proc newPeerInfo(
    listenAddrs: seq[MultiAddress] = @[],
    announcedAddrs: seq[MultiAddress] = @[],
    notifyDebounce = ZeroDuration,
): PeerInfo {.raises: [LPError].} =
  PeerInfo.new(
    PrivateKey.random(PKScheme.Ed25519, rng()).get(),
    listenAddrs,
    announcedAddrs = announcedAddrs,
    notifyDebounce = notifyDebounce,
  )

proc constantMapper(addrs: seq[MultiAddress]): AddressMapper =
  proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    addrs

proc interfaceProvider(hosts: seq[string]): NetworkInterfaceProvider =
  proc(addrFamily: AddressFamily): seq[InterfaceAddress] {.gcsafe, raises: [].} =
    var res: seq[InterfaceAddress]
    for host in hosts:
      let address =
        try:
          InterfaceAddress.init(initTAddress(host), 24)
        except TransportAddressError:
          raiseAssert "test address is valid: " & host
      if address.host.family == addrFamily:
        res.add(address)
    res

suite "AddressManager observations":
  teardown:
    checkTrackers()

  asyncTest "Calculate the most oberserved IP correctly":
    let manager = newStartedManager(minCount = 3)

    # Calculate the most oberserved IP4 correctly
    let mostObservedIP4AndPort = ma("/ip4/1.2.3.0/tcp/1")
    let maIP4 = ma("/ip4/0.0.0.0/tcp/80")

    check:
      manager.addObservation(mostObservedIP4AndPort)
      manager.addObservation(mostObservedIP4AndPort)

      manager.externalAddrFor(maIP4) == maIP4

      manager.addObservation(ma("/ip4/1.2.3.0/tcp/2"))
      manager.addObservation(ma("/ip4/1.2.3.1/tcp/1"))

      manager.externalAddrFor(maIP4) == ma("/ip4/1.2.3.0/tcp/80")
      manager.getMostObservedProtosAndPorts().len == 0

      manager.addObservation(mostObservedIP4AndPort)

      manager.getMostObservedProtosAndPorts() == @[mostObservedIP4AndPort]

    # Calculate the most oberserved IP6 correctly
    let mostObservedIP6AndPort = ma("/ip6/::2/tcp/1")
    let maIP6 = ma("/ip6/::1/tcp/80")

    check:
      manager.addObservation(mostObservedIP6AndPort)
      manager.addObservation(mostObservedIP6AndPort)

      manager.externalAddrFor(maIP6) == maIP6

      manager.addObservation(ma("/ip6/::2/tcp/2"))
      manager.addObservation(ma("/ip6/::3/tcp/1"))

      manager.externalAddrFor(maIP6) == ma("/ip6/::2/tcp/80")
      manager.getMostObservedProtosAndPorts().len == 1

      manager.addObservation(mostObservedIP6AndPort)

      manager.getMostObservedProtosAndPorts() ==
        @[mostObservedIP4AndPort, mostObservedIP6AndPort]

  asyncTest "replace first proto value by most observed when there is only one protocol":
    let manager = newStartedManager(minCount = 3)
    let mostObservedIP4AndPort = ma("/ip4/1.2.3.4/tcp/1")

    check:
      manager.addObservation(mostObservedIP4AndPort)
      manager.addObservation(mostObservedIP4AndPort)
      manager.addObservation(mostObservedIP4AndPort)

      manager.externalAddrFor(ma("/ip4/0.0.0.0")) == ma("/ip4/1.2.3.4")

  asyncTest "an address which is not a direct IP address with a transport is rejected":
    let
      manager = newStartedManager(maxSize = 2, minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    check manager.addObservation(observed)

    # the window is small: junk must neither be counted nor evict the good entry
    for _ in 0 ..< 4:
      check:
        not manager.addObservation(ma("/dns4/example.com/tcp/1"))
        not manager.addObservation(ma("/ip4/1.2.3.4"))
        not manager.addObservation(ma("/ip4/1.2.3.4/tcp/1/p2p-circuit"))

    check manager.getMostObservedProtosAndPorts() == @[observed]

  asyncTest "a threshold below one is raised to one":
    let
      manager = newStartedManager(maxSize = 0, minCount = 0)
      firstObserved = ma("/ip4/1.2.3.4/tcp/1")
      lastObserved = ma("/ip4/5.6.7.8/tcp/1")

    check:
      manager.addObservation(firstObserved)
      manager.addObservation(lastObserved)
      manager.getMostObservedProtosAndPorts() == @[lastObserved]

  asyncTest "a stopped manager rejects observations until it starts again":
    let
      manager = newManager(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    manager.start()
    check manager.addObservation(observed)

    manager.stop()
    check:
      not manager.addObservation(observed)
      manager.getMostObservedProtosAndPorts().len == 0

    manager.start()
    check:
      manager.addObservation(observed)
      manager.getMostObservedProtosAndPorts() == @[observed]

    manager.stop()

  asyncTest "start and stop are idempotent":
    let
      manager = newManager(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    manager.stop()
    check not manager.isStarted()

    manager.start()
    manager.start()

    check:
      manager.isStarted()
      manager.addObservation(observed)
      manager.getMostObservedProtosAndPorts() == @[observed]

    manager.stop()
    manager.stop()

    check:
      not manager.isStarted()
      manager.getMostObservedProtosAndPorts().len == 0

  asyncTest "a manager which never started rejects observations":
    let
      manager = newManager(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    check:
      not manager.isStarted()
      not manager.addObservation(observed)
      manager.getMostObservedProtosAndPorts().len == 0

    manager.start()
    check manager.addObservation(observed)
    manager.stop()

suite "AddressManager listen to external mapping":
  teardown:
    checkTrackers()

  asyncTest "the peers which observed a listen address decide its external address":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      otherListenAddr = ma("/ip4/192.168.0.3/tcp/2")
      peerInfo = newPeerInfo(@[listenAddr, otherListenAddr])
      manager = newManager(minCount = 1)

    manager.start(peerInfo)
    await peerInfo.update()

    check:
      manager.addObservation(ma("/ip4/1.2.3.4/tcp/9"), Opt.some(listenAddr))
      manager.addObservation(ma("/ip4/5.6.7.8/tcp/9"), Opt.some(otherListenAddr))

      manager.externalAddrFor(listenAddr) == ma("/ip4/1.2.3.4/tcp/1")
      manager.externalAddrFor(otherListenAddr) == ma("/ip4/5.6.7.8/tcp/2")

    manager.stop()

  asyncTest "an observation on an unknown local address feeds the shared window":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      ephemeral = ma("/ip4/192.168.0.2/tcp/54321")
      manager = newStartedManager(minCount = 1)

    check:
      manager.addObservation(ma("/ip4/1.2.3.4/tcp/9"), Opt.some(ephemeral))
      manager.externalAddrFor(listenAddr) == ma("/ip4/1.2.3.4/tcp/1")

    manager.stop()

suite "AddressManager candidates":
  teardown:
    checkTrackers()

  asyncTest "a candidate is stored once and refreshed on the next add":
    let
      manager = newStartedManager()
      address = ma("/ip4/1.2.3.4/tcp/1")

    check:
      manager.add(address, AddrSource.Listen)
      not manager.add(address, AddrSource.Upnp)
      manager.candidates().len == 1
      manager.candidates()[0].source == AddrSource.Upnp
      manager.candidates()[0].state == AddrState.Unverified

    manager.stop()

  asyncTest "a refresh keeps the state a verifier assigned":
    let
      manager = newStartedManager()
      address = ma("/ip4/1.2.3.4/tcp/1")

    manager.add(address, AddrSource.Listen)

    check:
      manager.update(address, AddrState.Confirmed)
      not manager.add(address, AddrSource.Listen)
      manager.candidates()[0].state == AddrState.Confirmed

    manager.stop()

  asyncTest "update and remove report an unknown address":
    let
      manager = newStartedManager()
      address = ma("/ip4/1.2.3.4/tcp/1")

    check:
      not manager.update(address, AddrState.Confirmed)
      not manager.remove(address)

    manager.add(address, AddrSource.Listen)

    check:
      manager.remove(address)
      manager.candidates().len == 0

    manager.stop()

  asyncTest "a candidate is dropped once its ttl runs out":
    let
      manager = newStartedManager(candidateTtl = 10.milliseconds)
      address = ma("/ip4/1.2.3.4/tcp/1")

    manager.add(address, AddrSource.Listen)
    check manager.candidates().len == 1

    await sleepAsync(30.milliseconds)
    check manager.candidates().len == 0

    manager.stop()

  asyncTest "confirmedAddrs filters by state and by family":
    let
      manager = newStartedManager()
      ip4 = ma("/ip4/1.2.3.4/tcp/1")
      ip6 = ma("/ip6/::2/tcp/1")

    manager.add(ip4, AddrSource.Listen)
    manager.add(ip6, AddrSource.Listen)

    check manager.confirmedAddrs().len == 0

    manager.update(ip4, AddrState.Confirmed)
    manager.update(ip6, AddrState.Confirmed)

    check:
      manager.confirmedAddrs() == @[ip4, ip6]
      manager.confirmedAddrs(Opt.some(IpAddressFamily.IPv4)) == @[ip4]
      manager.confirmedAddrs(Opt.some(IpAddressFamily.IPv6)) == @[ip6]

    manager.stop()

suite "AddressManager address mapper":
  teardown:
    checkTrackers()

  asyncTest "the manager is the only mapper the PeerInfo runs":
    let
      peerInfo = newPeerInfo(@[ma("/ip4/1.2.3.4/tcp/1")])
      manager = newManager()

    check peerInfo.addressMappers.len == 0

    manager.start(peerInfo)
    check peerInfo.addressMappers.len == 1

    manager.stop()
    check peerInfo.addressMappers.len == 0

  asyncTest "the manager expands the wildcard addresses":
    let
      peerInfo = newPeerInfo(@[ma("/ip4/0.0.0.0/tcp/1")])
      manager = newManager()

    manager.networkInterfaceProvider = interfaceProvider(@["127.0.0.1:0", "10.0.0.1:0"])
    manager.start(peerInfo)
    await peerInfo.update()

    check peerInfo.addrs == @[ma("/ip4/127.0.0.1/tcp/1"), ma("/ip4/10.0.0.1/tcp/1")]

    manager.networkInterfaceProvider = nil
    await peerInfo.update()

    check peerInfo.addrs == @[ma("/ip4/0.0.0.0/tcp/1")]

    manager.stop()

  asyncTest "a mapper tags the addresses it adds with its own source":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      relayAddr = ma("/ip4/1.2.3.4/tcp/1/p2p-circuit")
      peerInfo = newPeerInfo(@[listenAddr])
      manager = newManager()

    manager.start(peerInfo)
    manager.addMapper(constantMapper(@[listenAddr, relayAddr]), AddrSource.Circuit)
    await peerInfo.update()

    check:
      peerInfo.addrs == @[listenAddr, relayAddr]
      manager.candidates().len == 2

    for candidate in manager.candidates():
      if candidate.address == listenAddr:
        check candidate.source == AddrSource.Listen
      else:
        check candidate.source == AddrSource.Circuit

    manager.stop()

  asyncTest "a mapper which stops producing an address withdraws its candidate":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      mappedAddr = ma("/ip4/1.2.3.4/tcp/1")
      peerInfo = newPeerInfo(@[listenAddr])
      manager = newManager()
      mapper = constantMapper(@[mappedAddr])

    manager.start(peerInfo)
    manager.addMapper(mapper, AddrSource.Upnp)
    await peerInfo.update()

    check:
      peerInfo.addrs == @[mappedAddr]
      manager.candidates().len == 1

    manager.removeMapper(mapper)
    await peerInfo.update()

    check:
      peerInfo.addrs == @[listenAddr]
      manager.candidates().len == 1
      manager.candidates()[0].address == listenAddr

    manager.stop()

  asyncTest "a candidate a feeder adds is announced and survives the chain":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      fedAddr = ma("/ip4/1.2.3.4/tcp/1")
      peerInfo = newPeerInfo(@[listenAddr])
      manager = newManager()

    manager.start(peerInfo)
    manager.add(fedAddr, AddrSource.Circuit)
    await peerInfo.update()

    check peerInfo.addrs == @[listenAddr, fedAddr]

    check manager.remove(fedAddr)
    await peerInfo.update()

    check peerInfo.addrs == @[listenAddr]

    manager.stop()

  asyncTest "an unreachable candidate is not announced":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      peerInfo = newPeerInfo(@[listenAddr])
      manager = newManager()

    manager.start(peerInfo)
    await peerInfo.update()
    check peerInfo.addrs == @[listenAddr]

    manager.update(listenAddr, AddrState.Unreachable)
    await peerInfo.update()

    check:
      peerInfo.addrs.len == 0
      manager.candidates().len == 1

    manager.stop()

  asyncTest "an explicit announce list wins, and the mappers still see the bound addrs":
    let
      announced = ma("/ip4/1.2.3.4/tcp/1")
      expanded = ma("/ip4/10.0.0.1/tcp/1")
      mapped = ma("/ip4/9.9.9.9/tcp/2")
      peerInfo = newPeerInfo(@[ma("/ip4/0.0.0.0/tcp/1")], @[announced])
      manager = newManager()

    var mapperInput: seq[MultiAddress]
    let recordingMapper: AddressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      mapperInput = listenAddrs
      @[mapped]

    manager.networkInterfaceProvider = interfaceProvider(@["10.0.0.1:0"])
    manager.start(peerInfo)
    manager.addMapper(recordingMapper, AddrSource.Upnp)
    await peerInfo.update()

    check:
      peerInfo.addrs == @[announced]
      mapperInput == @[expanded]
      manager.candidates().anyIt(
        it.address == announced and it.source == AddrSource.Announced
      )
      manager.candidates().anyIt(it.address == mapped and it.source == AddrSource.Upnp)

    manager.stop()

suite "Switch-owned AddressManager":
  teardown:
    checkTrackers()

  asyncTest "the switch owns the manager and identify holds the same instance":
    let switch = makeStandardSwitch(ma("/memorytransport/*"))

    check:
      not switch.addressManager.isNil()
      switch.peerStore.identify.addressManager == switch.addressManager

  asyncTest "a started switch runs one mapper, the manager's own":
    let switch = makeStandardSwitchBuilder(TcpAutoAddress)
      .withNAT(autonatConfig(AutonatV1))
      .withWildcardResolver()
      .build()

    await switch.start()
    defer:
      await switch.stop()

    check:
      switch.peerInfo.addressMappers.len == 1
      switch.addressManager.mapperSources() == @[AddrSource.IdentifyObserved]

  asyncTest "identify feeds the manager which the switch owns":
    let
      dialer = makeStandardSwitchBuilder(TcpAutoAddress)
        .withAddressManager(AddressManagerConfig(minCount: 1))
        .build()
      listener = makeStandardSwitch(TcpAutoAddress)

    await allFutures(dialer.start(), listener.start())
    defer:
      await allFutures(dialer.stop(), listener.stop())

    # the dialer identifies the listener, which reports back the address it sees
    await dialer.connect(listener.peerInfo.peerId, listener.peerInfo.addrs)

    let observed = dialer.addressManager.getMostObservedProtosAndPorts()
    check:
      observed.len == 1
      observed[0].contains(multiCodec("ip4")).get(false)

  asyncTest "the builder config sets the thresholds":
    let
      switch = makeStandardSwitchBuilder(ma("/memorytransport/*"))
        .withAddressManager(AddressManagerConfig(maxSize: 2, minCount: 1))
        .build()
      firstObserved = ma("/ip4/1.2.3.4/tcp/1")
      lastObserved = ma("/ip4/5.6.7.8/tcp/1")

    await switch.start()
    defer:
      await switch.stop()

    # minCount is 1, so a single observation is enough
    check:
      switch.addressManager.addObservation(firstObserved)
      switch.addressManager.getMostObservedProtosAndPorts() == @[firstObserved]

    # maxSize is 2, so the third observation drops the first one
    check:
      switch.addressManager.addObservation(lastObserved)
      switch.addressManager.addObservation(lastObserved)
      switch.addressManager.getMostObservedProtosAndPorts() == @[lastObserved]

  asyncTest "the deprecated builder hook still wires the given manager":
    let addressManager = newManager(maxSize = 1, minCount = 1)

    {.push warning[Deprecated]: off.}
    let switch = makeStandardSwitchBuilder(ma("/memorytransport/*"))
      .withObservedAddrManager(addressManager)
      .build()
    {.pop.}

    check:
      switch.addressManager == addressManager
      switch.peerStore.identify.addressManager == addressManager

  asyncTest "the switch starts and stops the manager":
    let switch = makeStandardSwitch(ma("/memorytransport/*"))

    check not switch.addressManager.isStarted()

    await switch.start()
    check switch.addressManager.isStarted()

    await switch.stop()
    check not switch.addressManager.isStarted()

  asyncTest "stopping the switch drops the observations":
    let
      switch = makeStandardSwitch(ma("/memorytransport/*"))
      observed = ma("/ip4/1.2.3.4/tcp/1")
      listenAddr = ma("/ip4/0.0.0.0/tcp/80")

    await switch.start()

    for _ in 0 ..< 3:
      check switch.addressManager.addObservation(observed)

    check:
      switch.addressManager.getMostObservedProtosAndPorts() == @[observed]
      switch.addressManager.externalAddrFor(listenAddr) == ma("/ip4/1.2.3.4/tcp/80")

    await switch.stop()

    check:
      switch.addressManager.getMostObservedProtosAndPorts().len == 0
      switch.addressManager.externalAddrFor(listenAddr) == listenAddr

suite "PeerInfo observer debounce":
  teardown:
    checkTrackers()

  asyncTest "a burst raises one immediate notification and one trailing one":
    let peerInfo = newPeerInfo(notifyDebounce = 50.milliseconds)
    var notifications = 0

    peerInfo.addObserver(
      proc(_: PeerInfo) {.gcsafe, raises: [].} =
        notifications.inc()
    )

    for _ in 0 ..< 10:
      peerInfo.notifyObservers()

    check notifications == 1

    await sleepAsync(100.milliseconds)
    check notifications == 2

    await peerInfo.stopNotifications()

  asyncTest "a zero debounce raises every notification":
    let peerInfo = newPeerInfo()
    var notifications = 0

    peerInfo.addObserver(
      proc(_: PeerInfo) {.gcsafe, raises: [].} =
        notifications.inc()
    )

    for _ in 0 ..< 10:
      peerInfo.notifyObservers()

    check notifications == 10

    await peerInfo.stopNotifications()
