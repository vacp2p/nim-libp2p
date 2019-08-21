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
  server*: StreamServer

proc connCb(server: StreamServer,
            client: StreamTransport) {.gcsafe, async.} =
  let t: Transport = cast[Transport](server.udata)
  discard t.connHandler(server, client)

method init*(t: TcpTransport) =
  t.multicodec = multiCodec("tcp")

method close*(t: TcpTransport): Future[void] {.async.} =
  ## start the transport
  await procCall Transport(t).close() # call base close

  t.server.stop()
  await t.server.closeWait()

method listen*(t: TcpTransport): Future[void] {.async.} =
  let listenFuture: Future[void] = newFuture[void]()
  result = listenFuture

  ## listen on the transport
  let server = createStreamServer(t.ma, connCb, {}, t)
  t.server = server
  server.start()

method dial*(t: TcpTransport, address: MultiAddress): Future[Connection] {.async.} =
  ## dial a peer
  let client: StreamTransport = await connect(address)
  result = await t.connHandler(t.server, client)
