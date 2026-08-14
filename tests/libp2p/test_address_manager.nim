# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sequtils
import chronos
import
  ../../libp2p/
    [address_manager, crypto/crypto, multiaddress, multicodec, peerinfo, switch]
import ../../libp2p/services/natservice
import ../tools/[unittest, crypto, switch_builder, multiaddress]

proc newManager(
    maxSize = DefaultObservedAddrMaxSize, minCount = DefaultObservedAddrMinCount
): AddressManager =
  AddressManager.new(AddressManagerConfig(maxSize: maxSize, minCount: minCount))

proc newStartedManager(
    maxSize = DefaultObservedAddrMaxSize, minCount = DefaultObservedAddrMinCount
): AddressManager =
  let manager = newManager(maxSize, minCount)
  manager.start()
  manager

proc newPeerInfo(
    listenAddrs: seq[MultiAddress] = @[], announcedAddrs: seq[MultiAddress] = @[]
): PeerInfo {.raises: [LPError].} =
  PeerInfo.new(
    PrivateKey.random(PKScheme.Ed25519, rng()).get(),
    listenAddrs,
    announcedAddrs = announcedAddrs,
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

  asyncTest "Calculate the most observed IP correctly":
    let manager = newStartedManager(minCount = 3)

    let mostObservedIP4AndPort = ma("/ip4/1.2.3.0/tcp/1")
    let maIP4 = ma("/ip4/0.0.0.0/tcp/80")

    check:
      manager.addObservation(mostObservedIP4AndPort)
      manager.addObservation(mostObservedIP4AndPort)

      manager.externalAddrFor(maIP4) == maIP4

      manager.addObservation(ma("/ip4/1.2.3.0/tcp/2"))
      manager.addObservation(ma("/ip4/1.2.3.1/tcp/1"))

      manager.externalAddrFor(maIP4) == ma("/ip4/1.2.3.0/tcp/80")
      manager.mostObservedProtosAndPorts().len == 0

      manager.addObservation(mostObservedIP4AndPort)

      manager.mostObservedProtosAndPorts() == @[mostObservedIP4AndPort]

    let mostObservedIP6AndPort = ma("/ip6/::2/tcp/1")
    let maIP6 = ma("/ip6/::1/tcp/80")

    check:
      manager.addObservation(mostObservedIP6AndPort)
      manager.addObservation(mostObservedIP6AndPort)

      manager.externalAddrFor(maIP6) == maIP6

      manager.addObservation(ma("/ip6/::2/tcp/2"))
      manager.addObservation(ma("/ip6/::3/tcp/1"))

      manager.externalAddrFor(maIP6) == ma("/ip6/::2/tcp/80")
      manager.mostObservedProtosAndPorts().len == 1

      manager.addObservation(mostObservedIP6AndPort)

      manager.mostObservedProtosAndPorts() ==
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

    check manager.mostObservedProtosAndPorts() == @[observed]

  asyncTest "a threshold below one is raised to one":
    let
      manager = newStartedManager(maxSize = 0, minCount = 0)
      firstObserved = ma("/ip4/1.2.3.4/tcp/1")
      lastObserved = ma("/ip4/5.6.7.8/tcp/1")

    check:
      manager.addObservation(firstObserved)
      manager.addObservation(lastObserved)
      manager.mostObservedProtosAndPorts() == @[lastObserved]

  asyncTest "a stopped manager rejects observations until it starts again":
    let
      manager = newManager(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    manager.start()
    check manager.addObservation(observed)

    manager.stop()
    check:
      not manager.addObservation(observed)
      manager.mostObservedProtosAndPorts().len == 0

    manager.start()
    check:
      manager.addObservation(observed)
      manager.mostObservedProtosAndPorts() == @[observed]

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
      manager.mostObservedProtosAndPorts() == @[observed]

    manager.stop()
    manager.stop()

    check:
      not manager.isStarted()
      manager.mostObservedProtosAndPorts().len == 0

  asyncTest "a manager which never started rejects observations":
    let
      manager = newManager(minCount = 1)
      observed = ma("/ip4/1.2.3.4/tcp/1")

    check:
      not manager.isStarted()
      not manager.addObservation(observed)
      manager.mostObservedProtosAndPorts().len == 0

    manager.start()
    check manager.addObservation(observed)
    manager.stop()

suite "AddressManager wildcard expansion":
  let provider =
    interfaceProvider(@["127.0.0.1:0", "192.168.1.22:0", "[::1]:0", "[fe80::1]:0"])

  test "an IPv4 wildcard expands to the IPv4 interfaces only":
    check expandWildcardAddresses(provider, @[ma("/ip4/0.0.0.0/tcp/4001")]) ==
      @[ma("/ip4/127.0.0.1/tcp/4001"), ma("/ip4/192.168.1.22/tcp/4001")]

  test "an IPv6 wildcard expands to the IPv6 and the IPv4 interfaces":
    # TODO: vacp2p/nim-libp2p#2757
    check expandWildcardAddresses(provider, @[ma("/ip6/::/tcp/4001")]) ==
      @[
        ma("/ip6/::1/tcp/4001"),
        ma("/ip6/fe80::1/tcp/4001"),
        ma("/ip4/127.0.0.1/tcp/4001"),
        ma("/ip4/192.168.1.22/tcp/4001"),
      ]

  test "a non-wildcard and a non-IP address pass through unchanged":
    let inputs = @[
      ma("/ip4/1.2.3.4/tcp/4001"),
      ma("/dns4/example.com/tcp/4001"),
      ma("/memorytransport/addr-1"),
    ]
    check expandWildcardAddresses(provider, inputs) == inputs

suite "AddressManager candidates":
  teardown:
    checkTrackers()

  asyncTest "a candidate is stored once and keeps every source which adds it":
    let
      manager = newStartedManager()
      address = ma("/ip4/1.2.3.4/tcp/1")

    check:
      manager.add(address, AddrSource.Listen)
      not manager.add(address, AddrSource.Upnp)
      manager.candidates().len == 1
      manager.candidates()[0].sources == {AddrSource.Listen, AddrSource.Upnp}
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
        check candidate.sources == {AddrSource.Listen}
      else:
        check candidate.sources == {AddrSource.Circuit}

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

  asyncTest "a candidate a feeder also offers survives the mapper which drops it":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      mappedAddr = ma("/ip4/1.2.3.4/tcp/1")
      peerInfo = newPeerInfo(@[listenAddr])
      manager = newManager()
      mapper = constantMapper(@[listenAddr, mappedAddr])

    manager.start(peerInfo)
    manager.addMapper(mapper, AddrSource.Upnp)
    await peerInfo.update()

    manager.add(mappedAddr, AddrSource.Autonat)

    check manager.candidates().anyIt(
      it.address == mappedAddr and it.sources == {AddrSource.Upnp, AddrSource.Autonat}
    )

    manager.removeMapper(mapper)
    await peerInfo.update()

    check:
      peerInfo.addrs == @[listenAddr, mappedAddr]
      manager.candidates().anyIt(
        it.address == mappedAddr and it.sources == {AddrSource.Autonat}
      )

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
        it.address == announced and it.sources == {AddrSource.Announced}
      )
      manager.candidates().anyIt(
        it.address == mapped and it.sources == {AddrSource.Upnp}
      )

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
      switch.addressManager.mapperSources() == @[AddrSource.Autonat]

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

    let observed = dialer.addressManager.mostObservedProtosAndPorts()
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
      switch.addressManager.mostObservedProtosAndPorts() == @[firstObserved]

    # maxSize is 2, so the third observation drops the first one
    check:
      switch.addressManager.addObservation(lastObserved)
      switch.addressManager.addObservation(lastObserved)
      switch.addressManager.mostObservedProtosAndPorts() == @[lastObserved]

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
      switch.addressManager.mostObservedProtosAndPorts() == @[observed]
      switch.addressManager.externalAddrFor(listenAddr) == ma("/ip4/1.2.3.4/tcp/80")

    await switch.stop()

    check:
      switch.addressManager.mostObservedProtosAndPorts().len == 0
      switch.addressManager.externalAddrFor(listenAddr) == listenAddr
