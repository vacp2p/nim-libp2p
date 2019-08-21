## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import transport, wire, connection, multiaddress, connection, multicodec

type TcpTransport* = ref object of Transport
  fd*: AsyncFD
  server*: StreamServer

proc connHandler(server: StreamServer,
                 client: StreamTransport): Future[Connection] {.gcsafe, async.} =
  let t: TcpTransport = cast[TcpTransport](server.udata)
  let conn: Connection = newConnection(newAsyncStreamReader(client),
                                       newAsyncStreamWriter(client))
  let connHolder: ConnHolder = ConnHolder(connection: conn,
                                          connFuture: t.handler(conn))
  t.connections.add(connHolder)
  result = conn

proc connCb(server: StreamServer,
                 client: StreamTransport) {.gcsafe, async.} =
  discard connHandler(server, client)

method init*(t: TcpTransport) =
  t.multicodec = multiCodec("tcp")

method close*(t: TcpTransport): Future[void] {.async.} =
  ## start the transport
  result = t.server.closeWait()

method listen*(t: TcpTransport): Future[void] {.async.} =
  let listenFuture: Future[void] = newFuture[void]()
  result = listenFuture

  proc initTransport(server: StreamServer, fd: AsyncFD): StreamTransport {.gcsafe.} =
    t.server = server
    t.fd = fd
    listenFuture.complete()

  ## listen on the transport
  let server = createStreamServer(t.ma,
                                  connCb,
                                  {},
                                  t,
                                  asyncInvalidSocket,
                                  100,
                                  DefaultStreamBufferSize,
                                  nil,
                                  initTransport)
  server.start()

method dial*(t: TcpTransport,
             address: MultiAddress): Future[Connection] {.async.} =
  ## dial a peer
  let client: StreamTransport = await connect(address)
  result = await connHandler(t.server, client)
