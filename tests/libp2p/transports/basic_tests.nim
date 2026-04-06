# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results
import
  ../../../libp2p/[
    stream/connection,
    transports/transport,
    transports/tcptransport,
    transports/tortransport,
    transports/wstransport,
    transports/quictransport,
    upgrademngrs/upgrade,
    multiaddress,
    multicodec,
  ]
import ../../tools/[unittest]
import ./utils

template basicTransportTest*(
    provider: TransportProvider,
    address: string,
    validWireAddresses: seq[string],
    validNonWireAddresses: seq[string],
    invalidAddresses: seq[string],
) =
  block:
    let transportProvider = provider

    asyncTestConcurrent "can handle local address":
      let ma = @[MultiAddress.init(address).tryGet()]

      let transport = transportProvider()
      await transport.start(ma)
      defer:
        await transport.stop()

      check transport.handles(transport.addrs[0])

    asyncTestConcurrent "handle dial cancellation":
      let ma = @[MultiAddress.init(address).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      let client = transportProvider()
      defer:
        await allFutures(client.stop(), server.stop())

      let connFut = client.dial(server.addrs[0])
      await connFut.cancelAndWait()

      check connFut.cancelled

    asyncTestConcurrent "handle accept cancellation":
      let ma = @[MultiAddress.init(address).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      defer:
        await server.stop()

      let acceptFut = server.accept()
      await acceptFut.cancelAndWait()

      check acceptFut.cancelled

    asyncTestConcurrent "stopping transport kills connections":
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

    asyncTestConcurrent "transport start/stop events":
      let ma = @[MultiAddress.init(address).tryGet()]
      let transport = transportProvider()

      await transport.start(ma)
      check await transport.onRunning.wait().withTimeout(1.seconds)

      await transport.stop()
      check await transport.onStop.wait().withTimeout(1.seconds)

    asyncTestConcurrent "start succeeds for valid wire addresses":
      for ma in validWireAddresses:
        let transport = transportProvider()
        await transport.start(@[MultiAddress.init(ma).tryGet()])
        await transport.stop()

    # TODO: See issue nim-libp2p#2230
    asyncTestConcurrent "start fails for valid non-wire addresses":
      for addrs in validNonWireAddresses:
        let transport = transportProvider()
        let ma = MultiAddress.init(addrs).tryGet()

        if transport of TcpTransport:
          expect ResultDefect:
            await transport.start(@[ma])
        elif transport of TorTransport:
          expect TransportStartError:
            await transport.start(@[ma])
        else:
          expect LPError:
            await transport.start(@[ma])

    # TODO: See issue nim-libp2p#2230
    asyncTestConcurrent "start behaviour for invalid addresses":
      for addrs in invalidAddresses:
        let transport = transportProvider()
        let ma = MultiAddress.init(addrs).tryGet()

        if transport of TcpTransport:
          await transport.start(@[ma])
          await transport.stop()
        elif transport of TorTransport:
          expect TransportStartError:
            await transport.start(@[ma])
        elif transport of QuicTransport:
          if UDP.match(ma):
            # matches "/ip4/127.0.0.1/udp/1234", UDP without quic-v1
            await transport.start(@[ma])
            await transport.stop()
          else:
            expect LPError:
              await transport.start(@[ma])
        elif transport of WsTransport:
          if TCP.match(ma):
            # matches "/ip4/127.0.0.1/tcp/1234", Missing /ws or /wss
            await transport.start(@[ma])
            await transport.stop()
          else:
            expect LPError:
              await transport.start(@[ma])

    asyncTestConcurrent "multiaddress validation - accept valid addresses":
      let transport = transportProvider()

      for validAddress in validWireAddresses & validNonWireAddresses:
        check transport.handles(MultiAddress.init(validAddress).tryGet())

    asyncTestConcurrent "multiaddress validation - reject invalid addresses":
      let transport = transportProvider()

      for invalidAddress in invalidAddresses:
        check not transport.handles(MultiAddress.init(invalidAddress).tryGet())

    asyncTestConcurrent "address normalization - port assignment":
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

    asyncTestConcurrent "cannot bind second listener to same port":
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

    asyncTestConcurrent "dial with malformed multiaddresses":
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

    asyncTestConcurrent "observedAddr and localAddr are populated on connections":
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
