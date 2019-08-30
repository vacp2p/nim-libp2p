## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import transport, wire, connection,
       multiaddress, connection,
       multicodec, chronosstream

type TcpTransport* = ref object of Transport
  server*: StreamServer

proc connHandler*(t: Transport,
                  server: StreamServer,
                  client: StreamTransport): 
                  Future[Connection] {.async, gcsafe.} =
  let conn: Connection = newConnection(newChronosStream(server, client))
  let handlerFut = if t.handler == nil: nil else: t.handler(conn)
  let connHolder: ConnHolder = ConnHolder(connection: conn,
                                          connFuture: handlerFut)
  t.connections.add(connHolder)
  result = conn

proc connCb(server: StreamServer,
            client: StreamTransport) {.async, gcsafe.} =
  let t: Transport = cast[Transport](server.udata)
  discard t.connHandler(server, client)

method init*(t: TcpTransport) =
  t.multicodec = multiCodec("tcp")

method close*(t: TcpTransport): Future[void] {.async, gcsafe.} =
  ## start the transport
  await procCall Transport(t).close() # call base

  t.server.stop()
  await t.server.closeWait()

method listen*(t: TcpTransport,
               ma: MultiAddress,
               handler: ConnHandler): 
               Future[void] {.async, gcsafe.} =
  await procCall Transport(t).listen(ma, handler) # call base

  ## listen on the transport
  let listenFuture: Future[void] = newFuture[void]()
  result = listenFuture

  let server = createStreamServer(t.ma, connCb, {}, t)
  t.server = server
  server.start()
  listenFuture.complete()

method dial*(t: TcpTransport,
             address: MultiAddress): 
             Future[Connection] {.async, gcsafe.} =
  ## dial a peer
  let client: StreamTransport = await connect(address)
  result = await t.connHandler(t.server, client)

method handles*(t: Transport, address: MultiAddress): bool {.gcsafe.} = true
