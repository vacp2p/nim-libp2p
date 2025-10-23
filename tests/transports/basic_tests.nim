{.used.}

import chronos, results
import
  ../../libp2p/
    [stream/connection, transports/transport, upgrademngrs/upgrade, multiaddress]

import ../helpers
import ./utils

template basicTransportTest*(provider: TransportBuilder, address: string) =
  block:
    let transportProvider = provider

    asyncTest "can handle local address":
      let ma = @[MultiAddress.init(address).tryGet()]

      let transport = transportProvider()
      await transport.start(ma)
      defer:
        await transport.stop()

      check transport.handles(transport.addrs[0])

    asyncTest "handle observedAddr":
      let ma = @[MultiAddress.init(address).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      let client = transportProvider()

      let acceptFut = server.accept()
      let clientConn = await client.dial(server.addrs[0])
      let serverConn = await acceptFut

      defer:
        await allFutures(clientConn.close(), serverConn.close())
        await allFutures(client.stop(), server.stop())

      # Tor transport doesn't provide observedAddr for privacy reasons
      if not isTorTransport(server.addrs[0]):
        check:
          server.handles(clientConn.observedAddr.get())
          client.handles(serverConn.observedAddr.get())

      check:
        # skip IP check, only check transport and port
        serverConn.localAddr.get()[3] == server.addrs[0][3]
        serverConn.localAddr.get()[4] == server.addrs[0][4]

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
