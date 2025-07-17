{.used.}

# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
import ../libp2p/[
  multiaddress, 
  transports/tcptransport, 
  transports/memorytransport,
  transports/quictransport,
  transports/wstransport,
  transports/tortransport,
  upgrademngrs/upgrade,
  crypto/crypto
]
import ./helpers, ./stubs/torstub

suite "Transport onRunning":
  asyncTest "onRunning event is fired when transport starts":
    let upgrader = Upgrade()
    let transport = TcpTransport.new(upgrade = upgrader)
    var eventFired = false
    
    proc onRunningHandler() {.async.} =
      await transport.onRunning.wait()
      eventFired = true
    
    asyncSpawn onRunningHandler()
    
    check:
      eventFired == false
      transport.running == false
    
    await transport.start(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])
    
    # Give the event handler time to run
    await sleepAsync(10.milliseconds)
    
    check:
      eventFired == true
      transport.running == true
    
    await transport.stop()

  asyncTest "onRunning event can be awaited":
    let upgrader = Upgrade()
    let transport = TcpTransport.new(upgrade = upgrader)
    
    let startFut = transport.start(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])
    
    await transport.onRunning.wait()
    
    check:
      transport.running == true
    
    await startFut
    await transport.stop()

  asyncTest "onRunning works with memory transport":
    let upgrader = Upgrade()
    let transport = MemoryTransport.new(upgrade = upgrader)
    var eventFired = false
    
    proc onRunningHandler() {.async.} =
      await transport.onRunning.wait()
      eventFired = true
    
    asyncSpawn onRunningHandler()
    
    await transport.start(@[])
    
    # Give the event handler time to run
    await sleepAsync(10.milliseconds)
    
    check:
      eventFired == true
      transport.running == true
    
    await transport.stop()

  asyncTest "onRunning works with quic transport":
    let upgrader = Upgrade()
    let privateKey = PrivateKey.random(ECDSA, (newRng())[]).tryGet()
    let transport = QuicTransport.new(upgrader, privateKey)
    var eventFired = false
    
    proc onRunningHandler() {.async.} =
      await transport.onRunning.wait()
      eventFired = true
    
    asyncSpawn onRunningHandler()
    
    await transport.start(@[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()])
    
    # Give the event handler time to run
    await sleepAsync(10.milliseconds)
    
    check:
      eventFired == true
      transport.running == true
    
    await transport.stop()

  asyncTest "onRunning works with websocket transport":
    let upgrader = Upgrade()
    let transport = WsTransport.new(upgrader)
    var eventFired = false
    
    proc onRunningHandler() {.async.} =
      await transport.onRunning.wait()
      eventFired = true
    
    asyncSpawn onRunningHandler()
    
    await transport.start(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0/ws").tryGet()])
    
    # Give the event handler time to run
    await sleepAsync(10.milliseconds)
    
    check:
      eventFired == true
      transport.running == true
    
    await transport.stop()

  asyncTest "onRunning works with tor transport (with stub)":
    # Setup Tor stub server
    let torServer = initTAddress("127.0.0.1", 9050.Port)
    let stub = TorServerStub.new()
    stub.registerAddr(
      "a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad.onion:80",
      "/ip4/127.0.0.1/tcp/8080"
    )
    let stubStartFut = stub.start(torServer)
    
    try:
      # Give stub time to start
      await sleepAsync(50.milliseconds)
      
      let upgrader = Upgrade()
      let transport = TorTransport.new(torServer, upgrade = upgrader)
      var eventFired = false
      
      proc onRunningHandler() {.async.} =
        await transport.onRunning.wait()
        eventFired = true
      
      asyncSpawn onRunningHandler()
      
      # Use a proper TcpOnion3 address format that the stub knows about
      await transport.start(@[
        MultiAddress.init("/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80").tryGet()
      ])
      
      # Give the event handler time to run
      await sleepAsync(50.milliseconds)
      
      check:
        eventFired == true
        transport.running == true
      
      await transport.stop()
    finally:
      await stubStartFut.cancelAndWait()
      await stub.stop()
