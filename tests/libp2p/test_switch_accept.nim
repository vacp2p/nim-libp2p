# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import sequtils
import chronos
import
  ../../libp2p/
    [builders, switch, dial, multiaddress, transports/transport, stream/connection]
import ../stubs/transportstub
import ../tools/[unittest, crypto, lifecycle, multiaddress, switch_builder]

proc newStubAcceptSwitch(
    behavior: StubAcceptBehavior, nilCount = 0, withTcp = false, maxIn = 0
): (Switch, MemoryTransportStub) =
  var addrs = @[MemoryAutoAddress()]
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
        MemoryTransportStub.new(config.upgr, rng(), behavior, nilCount)
    )
  if withTcp:
    b = b.withTcpTransport()
  if maxIn > 0:
    b = b.withMaxInOut(maxIn, 8)

  let switch = b.build()
  (switch, MemoryTransportStub(switch.transports[0]))

suite "Switch accept-loop failure handling":
  teardown:
    checkTrackers()

  asyncTest "accept raising exits the loop while the transport still looks reachable":
    # a single inbound slot lets us check the loop hands it back when accept fails
    let (server, transport) = newStubAcceptSwitch(RaiseAlways, maxIn = 1)
    startAndDeferStop(@[server])

    # the loop calls accept, it raises, and the loop returns and is not respawned
    checkUntilTimeout:
      server.acceptFuts[0].finished
    check transport.acceptCalls == 1

    # yet the transport still reports running and its address stays advertised,
    # so the switch keeps looking reachable while nothing is accepting
    check transport.running
    check transport.addrs[0] in server.peerInfo.listenAddrs

    check server.connManager.availableSlots(Direction.In) == 1

  asyncTest "accept returning nil is non-fatal and the loop keeps retrying":
    let (server, transport) = newStubAcceptSwitch(NilAlways)
    startAndDeferStop(@[server])

    # nil is treated as a transient miss, so the loop keeps calling accept indefinitely
    checkUntilTimeout:
      transport.acceptCalls >= 5 # arbitrary count
    check not server.acceptFuts[0].finished

  asyncTest "inbound connections are dropped after a transport's accept loop dies":
    let (server, transport) = newStubAcceptSwitch(RaiseAlways)
    let client = makeStandardSwitch(MemoryAutoAddress())
    startAndDeferStop(@[server, client])

    # wait until the server's accept loop has given up
    checkUntilTimeout:
      server.acceptFuts[0].finished

    # the server still advertises its address
    check transport.addrs[0] in server.peerInfo.listenAddrs
    # but nothing is accepting, so an inbound dial fails
    expect DialFailedError:
      await client.connect(server.peerInfo.peerId, server.peerInfo.addrs)

  asyncTest "the accept loop releases its slot on each nil so a one-slot transport recovers":
    const nilCount = 3
    # only one inbound slot and the loop pre-acquires it before every accept.
    # reaching a real accept after nilCount nils is possible only if each
    # nil released that slot, else the next getIncomingSlot would block forever
    let (server, transport) =
      newStubAcceptSwitch(NilThenAccept, nilCount = nilCount, maxIn = 1)
    let client = makeStandardSwitch(MemoryAutoAddress())
    startAndDeferStop(@[server, client])

    checkUntilTimeout:
      transport.acceptCalls > nilCount

    # the recovered accept serves a real inbound connection, and the one slot is used
    await client.connect(server.peerInfo.peerId, server.peerInfo.addrs)
    check client.isConnected(server.peerInfo.peerId)
    check server.connManager.availableSlots(Direction.In) == 0

  asyncTest "one transport's accept failure does not stop other transports from accepting":
    let (server, _) = newStubAcceptSwitch(RaiseAlways, withTcp = true)
    let client = makeStandardSwitch(TcpAutoAddress)
    startAndDeferStop(@[server, client])

    # the memory transport's accept loop has died
    checkUntilTimeout:
      server.acceptFuts[0].finished

    # but the TCP transport still accepts connections
    let tcpAddrs = server.peerInfo.addrs.filterIt(TCP.match(it))
    await client.connect(server.peerInfo.peerId, tcpAddrs)
    check client.isConnected(server.peerInfo.peerId)
