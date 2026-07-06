# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import sequtils
import chronos
import ../../libp2p/[builders, switch, dial, multiaddress, transports/transport]
import ../stubs/transportstub
import ../tools/[unittest, crypto, lifecycle, multiaddress, switch_builder]

var memoryAddressCounter {.threadvar.}: int

proc uniqueMemoryAddress(): MultiAddress =
  # a concrete memory address per switch, so the shared memory registry never
  # collides across tests, and so `start`/`accept` never need the wildcard rng
  inc memoryAddressCounter
  MultiAddress.init("/memorytransport/stub-" & $memoryAddressCounter).get()

proc newStubServer(
    behavior: StubAcceptBehavior, nilCount = 0, withTcp = false
): (Switch, MemoryTransportStub) =
  var addrs = @[uniqueMemoryAddress()]
  if withTcp:
    addrs.add(TcpAutoAddress)

  var b = SwitchBuilder
    .new()
    .withRng(rng())
    .withNoise()
    .withMplex()
    .withAddresses(addrs)
    .withTransport(
      proc(config: TransportConfig): Transport =
        MemoryTransportStub.new(config.upgr, behavior, nilCount)
    )
  if withTcp:
    b = b.withTcpTransport()

  let switch = b.build()
  (switch, MemoryTransportStub(switch.transports[0]))

suite "Switch accept-loop failure handling":
  teardown:
    checkTrackers()

  asyncTest "accept raising exits the loop while the transport still looks reachable":
    let (switch, stub) = newStubServer(RaiseAlways)
    startAndDeferStop(@[switch])

    # the loop calls accept, it raises, and the loop returns and is not respawned
    checkUntilTimeout:
      switch.acceptFuts[0].finished
    check stub.acceptCalls == 1

    # yet the transport still reports running and its address stays advertised,
    # so the switch keeps looking reachable while nothing is accepting
    check stub.running
    check stub.addrs[0] in switch.peerInfo.listenAddrs

  asyncTest "accept returning nil is non-fatal and the loop keeps retrying":
    let (switch, stub) = newStubServer(NilAlways)
    startAndDeferStop(@[switch])

    # nil is treated as a transient miss, so the loop keeps calling accept
    checkUntilTimeout:
      stub.acceptCalls >= 5
    check not switch.acceptFuts[0].finished

  asyncTest "inbound connections are dropped after a transport's accept loop dies":
    let (server, stub) = newStubServer(RaiseAlways)
    let client = makeStandardSwitch(MemoryAutoAddress())
    startAndDeferStop(@[server, client])

    # wait until the server's accept loop has given up
    checkUntilTimeout:
      server.acceptFuts[0].finished

    # the server still advertises its address
    check stub.addrs[0] in server.peerInfo.listenAddrs
    # but nothing is accepting, so an inbound dial fails
    expect DialFailedError:
      await client.connect(server.peerInfo.peerId, server.peerInfo.addrs)

  asyncTest "a transport recovers and accepts connections after transient nil failures":
    const nilCount = 3
    let (server, stub) = newStubServer(NilThenAccept, nilCount = nilCount)
    let client = makeStandardSwitch(MemoryAutoAddress())
    startAndDeferStop(@[server, client])

    # once it has returned nil `nilCount` times the loop enters the base accept,
    # registers the listener, and awaits an inbound connection
    checkUntilTimeout:
      stub.acceptCalls > nilCount

    # a real inbound connection is now accepted end-to-end
    await client.connect(server.peerInfo.peerId, server.peerInfo.addrs)
    check client.isConnected(server.peerInfo.peerId)

  asyncTest "one transport's accept failure does not stop other transports from accepting":
    let (server, stub) = newStubServer(RaiseAlways, withTcp = true)
    let client = makeStandardSwitch(TcpAutoAddress)
    startAndDeferStop(@[server, client])

    # the memory transport's accept loop has died
    checkUntilTimeout:
      server.acceptFuts[0].finished

    # but the TCP transport still accepts connections
    let tcpAddrs = server.peerInfo.addrs.filterIt(TCP.match(it))
    await client.connect(server.peerInfo.peerId, tcpAddrs)
    check client.isConnected(server.peerInfo.peerId)
