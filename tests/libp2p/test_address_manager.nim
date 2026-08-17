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

proc makeManager(
    maxSize = DefaultObservedAddrMaxSize, minCount = DefaultObservedAddrMinCount
): AddressManager =
  AddressManager.new(AddressManagerConfig(maxSize: maxSize, minCount: minCount))

proc makeStartedManager(
    maxSize = DefaultObservedAddrMaxSize, minCount = DefaultObservedAddrMinCount
): AddressManager =
  let manager = makeManager(maxSize, minCount)
  manager.start()
  manager

const VerifyInterval = 10.milliseconds

proc makeVerifyingManager(verifier: Verifier = nil): AddressManager =
  let manager = AddressManager.new(AddressManagerConfig(verifyInterval: VerifyInterval))
  manager.verifier = verifier
  manager.start()
  manager

proc makePeerInfo(
    listenAddrs: seq[MultiAddress] = @[],
    announcedAddrs: seq[MultiAddress] = @[],
    addressPolicy: PeerAddressPolicy = defaultAddressPolicy,
): PeerInfo {.raises: [LPError].} =
  PeerInfo.new(
    PrivateKey.random(PKScheme.Ed25519, rng()).get(),
    listenAddrs,
    announcedAddrs = announcedAddrs,
    addressPolicy = addressPolicy,
  )

proc constantMapper(addrs: seq[MultiAddress]): AddressMapper =
  proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    addrs

proc addingMapper(addrs: seq[MultiAddress]): AddressMapper =
  proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    listenAddrs & addrs

type StubVerifier = ref object of Verifier
  verdicts: seq[AddrVerdict]
  asked: seq[seq[MultiAddress]]
  ran: AsyncEvent
  delay: Duration

proc makeStubVerifier(
    verdicts: seq[AddrVerdict] = @[], delay = ZeroDuration
): StubVerifier =
  StubVerifier(verdicts: verdicts, ran: newAsyncEvent(), delay: delay)

method verify(
    self: StubVerifier, addresses: seq[MultiAddress]
): Future[seq[AddrVerdict]] {.async: (raises: [CancelledError]).} =
  self.asked.add(addresses)
  self.ran.fire()
  await sleepAsync(self.delay)
  self.verdicts

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
    let manager = makeStartedManager(minCount = 3)

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
    let manager = makeStartedManager(minCount = 3)
    let mostObservedIP4AndPort = ma("/ip4/1.2.3.4/tcp/1")

    check:
      manager.addObservation(mostObservedIP4AndPort)
      manager.addObservation(mostObservedIP4AndPort)
      manager.addObservation(mostObservedIP4AndPort)

      manager.externalAddrFor(ma("/ip4/0.0.0.0")) == ma("/ip4/1.2.3.4")

  asyncTest "an address which is not a direct IP address with a transport is rejected":
    let
      manager = makeStartedManager(maxSize = 2, minCount = 1)
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
      manager = makeStartedManager(maxSize = 0, minCount = 0)
      firstObserved = ma("/ip4/1.2.3.4/tcp/1")
      lastObserved = ma("/ip4/5.6.7.8/tcp/1")

    check:
      manager.addObservation(firstObserved)
      manager.addObservation(lastObserved)
      manager.mostObservedProtosAndPorts() == @[lastObserved]

  asyncTest "a stopped manager rejects observations until it starts again":
    let
      manager = makeManager(minCount = 1)
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
      manager = makeManager(minCount = 1)
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
      manager = makeManager(minCount = 1)
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
      manager = makeStartedManager()
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
      manager = makeStartedManager()
      address = ma("/ip4/1.2.3.4/tcp/1")

    manager.add(address, AddrSource.Listen)

    check:
      manager.update(address, AddrState.Confirmed)
      not manager.add(address, AddrSource.Listen)
      manager.candidates()[0].state == AddrState.Confirmed

    manager.stop()

  asyncTest "update and remove report an unknown address":
    let
      manager = makeStartedManager()
      address = ma("/ip4/1.2.3.4/tcp/1")

    check:
      not manager.update(address, AddrState.Confirmed)
      not manager.remove(address)

    manager.add(address, AddrSource.Listen)

    check:
      manager.remove(address)
      manager.candidates().len == 0

    manager.stop()

suite "AddressManager verification":
  teardown:
    checkTrackers()

  asyncTest "a candidate stays unverified while no verifier runs":
    let
      manager = makeVerifyingManager()
      address = ma("/ip4/1.2.3.4/tcp/1")

    manager.add(address, AddrSource.Listen)
    # long enough for the heartbeat to run, which without a verifier changes nothing
    await sleepAsync(VerifyInterval * 2)

    check:
      manager.candidates()[0].state == AddrState.Unverified
      manager.confirmedAddrs().len == 0

    manager.stop()

  asyncTest "the heartbeat verifies every candidate and applies the verdicts":
    let
      confirmed = ma("/ip4/1.2.3.4/tcp/1")
      unreachable = ma("/ip4/5.6.7.8/tcp/1")
      verifier = makeStubVerifier(
        @[
          AddrVerdict(address: confirmed, state: AddrState.Confirmed),
          AddrVerdict(address: unreachable, state: AddrState.Unreachable),
        ]
      )
      manager = makeVerifyingManager(verifier)

    manager.add(confirmed, AddrSource.Listen)
    manager.add(unreachable, AddrSource.Upnp)

    checkUntilTimeout:
      manager.confirmedAddrs() == @[confirmed]
      manager.candidates().anyIt(
        it.address == unreachable and it.state == AddrState.Unreachable
      )
      verifier.asked.anyIt(it == @[confirmed, unreachable])

    manager.stop()

  asyncTest "a verifier which runs out of time applies nothing and runs again":
    let
      address = ma("/ip4/1.2.3.4/tcp/1")
      verifier = makeStubVerifier(
        @[AddrVerdict(address: address, state: AddrState.Confirmed)], delay = 1.hours
      )
      manager = makeVerifyingManager(verifier)

    manager.add(address, AddrSource.Listen)

    checkUntilTimeout:
      verifier.asked.len >= 2
      manager.confirmedAddrs().len == 0

    manager.stop()

  asyncTest "stopping the manager stops the heartbeat":
    let
      address = ma("/ip4/1.2.3.4/tcp/1")
      verifier = makeStubVerifier()
      manager = makeVerifyingManager(verifier)

    manager.add(address, AddrSource.Listen)
    await verifier.ran.wait()

    manager.stop()
    let runs = verifier.asked.len
    manager.add(address, AddrSource.Listen)
    await sleepAsync(VerifyInterval * 2)

    check verifier.asked.len == runs

  asyncTest "an interval and a verifier set after start take effect without a stale wait":
    let
      address = ma("/ip4/1.2.3.4/tcp/1")
      verifier =
        makeStubVerifier(@[AddrVerdict(address: address, state: AddrState.Confirmed)])
      # the default interval is minutes; a stale first sleep would outlive the test
      manager = AddressManager.new()

    manager.start()
    manager.add(address, AddrSource.Listen)
    manager.verifier = verifier
    manager.verifyInterval = VerifyInterval

    checkUntilTimeout:
      manager.confirmedAddrs() == @[address]

    manager.stop()

  asyncTest "the reachability summary follows the candidate states":
    let
      manager = makeStartedManager()
      first = ma("/ip4/1.2.3.4/tcp/1")
      second = ma("/ip4/5.6.7.8/tcp/1")

    check manager.reachability() == NetworkReachability.Unknown

    manager.add(first, AddrSource.Listen)
    check manager.reachability() == NetworkReachability.Unknown

    manager.update(first, AddrState.Unreachable)
    check manager.reachability() == NetworkReachability.NotReachable

    manager.add(second, AddrSource.Upnp)
    manager.update(second, AddrState.Confirmed)
    check manager.reachability() == NetworkReachability.Reachable

    manager.stop()

  asyncTest "a verify run which changes the summary fires the handler once":
    let
      address = ma("/ip4/1.2.3.4/tcp/1")
      verifier =
        makeStubVerifier(@[AddrVerdict(address: address, state: AddrState.Confirmed)])
      manager = makeVerifyingManager(verifier)

    var notified: seq[NetworkReachability]
    manager.onReachabilityChange = proc(
        reachability: NetworkReachability
    ) {.async: (raises: [CancelledError]).} =
      notified.add(reachability)

    manager.add(address, AddrSource.Listen)

    checkUntilTimeout:
      notified == @[NetworkReachability.Reachable]

    # further runs repeat the same verdict, and the summary change fires no more
    await sleepAsync(VerifyInterval * 3)
    check notified == @[NetworkReachability.Reachable]

    manager.stop()

  asyncTest "a relayed candidate is never sent to the verifier":
    let
      relayAddr = ma("/ip4/1.2.3.4/tcp/1/p2p-circuit")
      directAddr = ma("/ip4/5.6.7.8/tcp/1")
      verifier = makeStubVerifier()
      manager = makeVerifyingManager(verifier)

    manager.add(relayAddr, AddrSource.Circuit)
    manager.add(directAddr, AddrSource.Listen)

    checkUntilTimeout:
      verifier.asked.len >= 1

    check verifier.asked.allIt(it == @[directAddr])

    manager.stop()

  asyncTest "the address policy keeps a banned candidate out of the dial requests":
    let
      privateAddr = ma("/ip4/192.168.0.2/tcp/1")
      publicAddr = ma("/ip4/8.8.8.8/tcp/1")
      verifier = makeStubVerifier()
      manager = AddressManager.new(AddressManagerConfig(verifyInterval: VerifyInterval))
      peerInfo = makePeerInfo(addressPolicy = publicRoutableAddressPolicy)

    manager.verifier = verifier
    manager.start(peerInfo)
    manager.add(privateAddr, AddrSource.Listen)
    manager.add(publicAddr, AddrSource.Listen)

    checkUntilTimeout:
      verifier.asked.len >= 1
    check verifier.asked.allIt(it == @[publicAddr])

    manager.stop()

  asyncTest "a refuted guess is not asked again on later runs":
    let
      directAddr = ma("/ip4/5.6.7.8/tcp/1")
      observed = ma("/ip4/8.8.8.8/tcp/9")
      verifier = makeStubVerifier(
        @[AddrVerdict(address: observed, state: AddrState.Unreachable)]
      )
      manager = AddressManager.new(
        AddressManagerConfig(verifyInterval: VerifyInterval, minCount: 1)
      )
      peerInfo = makePeerInfo()

    manager.verifier = verifier
    manager.deriveIdentifyCandidates = true
    manager.start(peerInfo)
    manager.add(directAddr, AddrSource.Listen)
    check manager.addObservation(observed)

    checkUntilTimeout:
      verifier.asked.len >= 3
    check verifier.asked.filterIt(observed in it).len == 1

    manager.stop()

  asyncTest "newer refutations evict the oldest refuted guess, which becomes eligible":
    let
      firstIp4 = ma("/ip4/8.8.8.8/tcp/1")
      secondIp4 = ma("/ip4/9.9.9.9/tcp/1")
      ip6 = ma("/ip6/2001:db8::1/tcp/1")
      verifier = makeStubVerifier(
        @[
          AddrVerdict(address: firstIp4, state: AddrState.Unreachable),
          AddrVerdict(address: secondIp4, state: AddrState.Unreachable),
          AddrVerdict(address: ip6, state: AddrState.Unreachable),
        ]
      )
      manager = AddressManager.new(
        AddressManagerConfig(verifyInterval: VerifyInterval, maxSize: 2, minCount: 1)
      )
      peerInfo = makePeerInfo()

    manager.verifier = verifier
    manager.deriveIdentifyCandidates = true
    manager.start(peerInfo)

    check manager.addObservation(firstIp4)
    checkUntilTimeout:
      verifier.asked.filterIt(firstIp4 in it).len == 1

    # two newer refutations fill the ring of two and evict the first guess
    check manager.addObservation(secondIp4)
    check manager.addObservation(ip6)
    checkUntilTimeout:
      verifier.asked.anyIt(secondIp4 in it)
      verifier.asked.anyIt(ip6 in it)

    # the evicted guess becomes a candidate again on a new observation
    check manager.addObservation(firstIp4)
    checkUntilTimeout:
      verifier.asked.filterIt(firstIp4 in it).len >= 2

    manager.stop()

  asyncTest "observations become candidates when derivation is enabled":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      observed = ma("/ip4/8.8.8.8/tcp/9")
      guessed = ma("/ip4/8.8.8.8/tcp/1")
      verifier = makeStubVerifier()
      manager = AddressManager.new(
        AddressManagerConfig(verifyInterval: VerifyInterval, minCount: 3)
      )
      peerInfo = makePeerInfo(@[listenAddr])

    manager.verifier = verifier
    manager.deriveIdentifyCandidates = true
    manager.start(peerInfo)

    for _ in 0 ..< 3:
      check manager.addObservation(observed)

    checkUntilTimeout:
      manager.candidates().anyIt(
        it.address == guessed and it.sources == {AddrSource.Identify}
      )
      manager.candidates().anyIt(
        it.address == observed and it.sources == {AddrSource.Identify}
      )

    manager.stop()

suite "AddressManager address mapper":
  teardown:
    checkTrackers()

  asyncTest "the manager is the only mapper the PeerInfo runs":
    let
      peerInfo = makePeerInfo(@[ma("/ip4/1.2.3.4/tcp/1")])
      manager = makeManager()

    check peerInfo.addressMappers.len == 0

    manager.start(peerInfo)
    check peerInfo.addressMappers.len == 1

    manager.stop()
    check peerInfo.addressMappers.len == 0

  asyncTest "the manager expands the wildcard addresses":
    let
      peerInfo = makePeerInfo(@[ma("/ip4/0.0.0.0/tcp/1")])
      manager = makeManager()

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
      peerInfo = makePeerInfo(@[listenAddr])
      manager = makeManager()

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
      peerInfo = makePeerInfo(@[listenAddr])
      manager = makeManager()
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
      peerInfo = makePeerInfo(@[listenAddr])
      manager = makeManager()
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
      peerInfo = makePeerInfo(@[listenAddr])
      manager = makeManager()

    manager.start(peerInfo)
    manager.add(fedAddr, AddrSource.Circuit)
    await peerInfo.update()

    check peerInfo.addrs == @[listenAddr, fedAddr]

    check manager.remove(fedAddr)
    await peerInfo.update()

    check peerInfo.addrs == @[listenAddr]

    manager.stop()

  asyncTest "a verified-unreachable candidate is not announced":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      fedAddr = ma("/ip4/1.2.3.4/tcp/1")
      peerInfo = makePeerInfo(@[listenAddr])
      manager = makeManager()

    manager.start(peerInfo)
    manager.add(fedAddr, AddrSource.Circuit)
    await peerInfo.update()
    check peerInfo.addrs == @[listenAddr, fedAddr]

    manager.update(listenAddr, AddrState.Unreachable)
    manager.update(fedAddr, AddrState.Unreachable)
    await peerInfo.update()

    check:
      peerInfo.addrs.len == 0
      manager.candidates().allIt(it.state == AddrState.Unreachable)

    manager.stop()

  asyncTest "an explicit announce list wins, and the mappers still see the bound addrs":
    let
      announced = ma("/ip4/1.2.3.4/tcp/1")
      expanded = ma("/ip4/10.0.0.1/tcp/1")
      mapped = ma("/ip4/9.9.9.9/tcp/2")
      peerInfo = makePeerInfo(@[ma("/ip4/0.0.0.0/tcp/1")], @[announced])
      manager = makeManager()

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

suite "AddressManager verify and announce":
  teardown:
    checkTrackers()

  asyncTest "multi-source candidates verify, and only confirmed or unverified announce":
    let
      listenAddr = ma("/ip4/192.168.0.2/tcp/1")
      upnpAddr = ma("/ip4/9.9.9.9/tcp/1")
      relayAddr = ma("/ip4/1.2.3.4/tcp/2/p2p-circuit")
      observed = ma("/ip4/8.8.8.8/tcp/9")
      guessed = ma("/ip4/8.8.8.8/tcp/1")
      verifier = makeStubVerifier(
        @[
          AddrVerdict(address: upnpAddr, state: AddrState.Confirmed),
          AddrVerdict(address: listenAddr, state: AddrState.Unreachable),
          AddrVerdict(address: guessed, state: AddrState.Unreachable),
        ]
      )
      manager = AddressManager.new(
        AddressManagerConfig(verifyInterval: VerifyInterval, minCount: 3)
      )
      peerInfo = makePeerInfo(@[listenAddr])

    manager.verifier = verifier
    manager.deriveIdentifyCandidates = true
    manager.start(peerInfo)
    manager.addMapper(addingMapper(@[upnpAddr]), AddrSource.Upnp)
    manager.addMapper(addingMapper(@[relayAddr]), AddrSource.Circuit)

    # identify reports: same address three times reaches the quorum
    for _ in 0 ..< 3:
      check manager.addObservation(observed)

    await peerInfo.update()

    checkUntilTimeout:
      # confirmed and unverified announce; verified-unreachable do not
      peerInfo.addrs == @[upnpAddr, relayAddr]
      manager.confirmedAddrs() == @[upnpAddr]
      manager.reachability() == NetworkReachability.Reachable

    check:
      # the relayed candidate is announced yet never verified
      verifier.asked.allIt(relayAddr notin it)
      # the refuted guess is dropped; the unverified observation stays unannounced
      manager.candidates().allIt(it.address != guessed)
      manager.candidates().anyIt(it.address == observed)

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
