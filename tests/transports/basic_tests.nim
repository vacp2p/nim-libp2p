{.used.}

import chronos
import results
import
  ../../libp2p/[
    stream/connection,
    transports/transport,
    upgrademngrs/upgrade,
    multiaddress,
    multicodec,
  ]

import ../helpers
import ./utils

template basicTransportTest*(
    transportProvider: TransportBuilder,
    address: string,
    validAddresses: seq[string],
    invalidAddresses: seq[string],
) =
  asyncTest "can handle local address":
    let ma = @[MultiAddress.init(address).tryGet()]

    let transport = transportProvider()
    await transport.start(ma)
    defer:
      await transport.stop()

    check transport.handles(transport.addrs[0])

  asyncTest "handle dial cancellation":
    let ma = @[MultiAddress.init(address).tryGet()]

    let server = transportProvider()
    await server.start(ma)
    let client = transportProvider()
    defer:
      await allFutures(client.stop(), server.stop())

    let connFut = client.dial(server.addrs[0])
    await connFut.cancelAndWait()

    check connFut.cancelled

  asyncTest "handle accept cancellation":
    let ma = @[MultiAddress.init(address).tryGet()]

    let server = transportProvider()
    await server.start(ma)
    defer:
      await server.stop()

    let acceptFut = server.accept()
    await acceptFut.cancelAndWait()

    check acceptFut.cancelled

  asyncTest "stopping transport kills connections":
    let ma = @[MultiAddress.init(address).tryGet()]

    let server = transportProvider()
    await server.start(ma)
    let client = transportProvider()

    let acceptFut = server.accept()
    let clientConn = await client.dial(server.addrs[0])
    let serverConn = await acceptFut

    await allFutures(client.stop(), server.stop())

    check:
      clientConn.closed()
      serverConn.closed()

  asyncTest "transport start/stop events":
    let ma = @[MultiAddress.init(address).tryGet()]
    let transport = transportProvider()

    await transport.start(ma)
    check await transport.onRunning.wait().withTimeout(1.seconds)

    await transport.stop()
    check await transport.onStop.wait().withTimeout(1.seconds)

  asyncTest "multiaddress validation - accept valid addresses":
    let transport = transportProvider()

    for validAddress in validAddresses:
      check transport.handles(MultiAddress.init(validAddress).tryGet())

  asyncTest "multiaddress validation - reject invalid addresses":
    let transport = transportProvider()

    for invalidAddress in invalidAddresses:
      check not transport.handles(MultiAddress.init(invalidAddress).tryGet())

  asyncTest "address normalization - port assignment":
    # Start with port 0 and verify it gets assigned a real port
    let ma = MultiAddress.init(address).tryGet()

    if isTorTransport(ma):
      # The advertised address is the onion3 address with a fixed, pre-configured port
      skip()
      return

    let transport = transportProvider()
    await transport.start(@[ma])
    defer:
      await transport.stop()

    let assignedPort = extractPort(transport.addrs[0])

    check:
      assignedPort > 0
      # Ensure IP address is the same
      transport.addrs[0][multiCodec("ip4")].get() == ma[multiCodec("ip4")].get()

  asyncTest "cannot bind second listener to same port":
    let ma = MultiAddress.init(address).tryGet()

    if isTcpTransport(ma):
      #TODO: Find out why doesn't throw for TCP
      skip()
      return

    let server = transportProvider()
    await server.start(@[ma])
    defer:
      await server.stop()

    # Try to bind client transport to same address
    let server2 = transportProvider()
    expect LPError:
      await server2.start(@[server.addrs[0]])

  asyncTest "dial with malformed multiaddresses":
    let ma = MultiAddress.init(address).tryGet()

    let client = transportProvider() # not started
    let server = transportProvider()
    await server.start(@[ma])
    defer:
      await server.stop()

    let invalid = MultiAddress.init("/ip4/127.0.0.1").tryGet()
    expect LPError:
      discard await server.dial("", invalid)
    expect LPError:
      discard await client.dial("", invalid)

  asyncTest "observedAddr and localAddr are populated on connections":
    let ma = MultiAddress.init(address).tryGet()

    if isTorTransport(ma):
      # Tor transport doesn't provide observedAddr for privacy reasons
      skip()
      return

    let server = transportProvider()
    await server.start(@[ma])
    let client = transportProvider()

    let acceptFut = server.accept()
    let clientConn = await client.dial(server.addrs[0])
    let serverConn = await acceptFut

    defer:
      await allFutures(clientConn.close(), serverConn.close())
      await allFutures(client.stop(), server.stop())

    # Verify all addresses are populated
    check:
      clientConn.observedAddr.isSome()
      clientConn.localAddr.isSome()
      serverConn.observedAddr.isSome()
      serverConn.localAddr.isSome()

    # Verify address symmetry and correctness
    check:
      clientConn.observedAddr.get() == serverConn.localAddr.get()
      serverConn.localAddr.get() == server.addrs[0]
      server.handles(clientConn.observedAddr.get())
      client.handles(serverConn.observedAddr.get())
