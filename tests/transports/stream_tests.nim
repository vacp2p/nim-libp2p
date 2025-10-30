{.used.}

import chronos, stew/byteutils
import ../../libp2p/[stream/connection, transports/transport, muxers/muxer]
import ../helpers
import ./utils

template streamTransportTest*(
    provider: TransportProvider, address: string, muxerProvider: StreamMuxerProvider
) =
  const serverMessage =
    "Privacy is necessary for an open society in the electronic age."
  const clientMessage = "We can be decentralised yet cooperative."

  asyncTest "transport e2e":
    let ma = @[MultiAddress.init(address).tryGet()]

    proc serverHandler(server: Transport) {.async.} =
      let conn = await server.accept()
      let muxer = muxerProvider(server, conn)
      muxer.streamHandler = proc(stream: Connection) {.async: (raises: []).} =
        try:
          var buffer: array[clientMessage.len, byte]
          await stream.readExactly(addr buffer, clientMessage.len)
          check string.fromBytes(buffer) == clientMessage

          await stream.write(serverMessage)
        except CatchableError:
          raiseAssert "should not happen"
        finally:
          await stream.close()
      asyncSpawn muxer.handle()

    proc runClient(server: Transport) {.async.} =
      let client = provider()
      let conn = await client.dial("", server.addrs[0])
      let muxer = muxerProvider(client, conn)
      asyncSpawn muxer.handle()

      let stream = await muxer.newStream()
      await stream.write(clientMessage)

      var buffer: array[serverMessage.len, byte]
      await stream.readExactly(addr buffer, serverMessage.len)
      check string.fromBytes(buffer) == serverMessage

      await stream.close()
      await client.stop()

    let server = provider()
    await server.start(ma)
    let serverHandlerFut = serverHandler(server)

    await runClient(server)
    await serverHandlerFut
    await server.stop()
