## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import oids
import chronos, chronicles, sequtils
import transport,
       ../errors,
       ../wire,
       ../multiaddress,
       ../multicodec,
       ../stream/connection,
       ../stream/chronosstream

logScope:
  topics = "tcptransport"

const
  TcpTransportTrackerName* = "libp2p.tcptransport"

type
  TcpTransport* = ref object of Transport
    server*: StreamServer
    clients: seq[StreamTransport]
    flags: set[ServerFlags]
    cleanups*: seq[Future[void]]
    handlers*: seq[Future[void]]

  TcpTransportTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

proc setupTcpTransportTracker(): TcpTransportTracker {.gcsafe.}

proc getTcpTransportTracker(): TcpTransportTracker {.gcsafe.} =
  result = cast[TcpTransportTracker](getTracker(TcpTransportTrackerName))
  if isNil(result):
    result = setupTcpTransportTracker()

proc dumpTracking(): string {.gcsafe.} =
  var tracker = getTcpTransportTracker()
  result = "Opened tcp transports: " & $tracker.opened & "\n" &
           "Closed tcp transports: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getTcpTransportTracker()
  result = (tracker.opened != tracker.closed)

proc setupTcpTransportTracker(): TcpTransportTracker =
  result = new TcpTransportTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTracking
  result.isLeaked = leakTransport
  addTracker(TcpTransportTrackerName, result)

proc connHandler*(t: TcpTransport,
                  client: StreamTransport,
                  initiator: bool): Connection =
  debug "Handling tcp connection", address = $client.remoteAddress,
                                   initiator = initiator,
                                   clients = t.clients.len

  let conn = Connection(
    ChronosStream.init(
      client,
      dir = if initiator:
        Direction.Out
      else:
        Direction.In))

  if not initiator:
    if not isNil(t.handler):
      t.handlers &= t.handler(conn)

  proc cleanup() {.async.} =
    try:
      await client.join() or conn.join()
      trace "Cleaning up client", addrs = $client.remoteAddress,
                                  conn = $conn.oid

      t.clients.keepItIf( it != client )
      if not(isNil(conn) and not conn.closed()):
        await conn.close()

      if not(isNil(client) and client.closed()):
        await client.closeWait()

      trace "Cleaned up client", addrs = $client.remoteAddress,
                                 conn = $conn.oid

    except CatchableError as exc:
      let useExc {.used.} = exc
      debug "Error cleaning up client", errMsg = exc.msg, s = conn

  t.clients.add(client)
  # All the errors are handled inside `cleanup()` procedure.
  asyncSpawn cleanup()

  try:
    conn.observedAddr = MultiAddress.init(client.remoteAddress).tryGet()
  except CatchableError as exc:
    trace "Unable to get remote address", exc = exc.msg

    if not isNil(client):
      client.close()

    raise exc

  return conn

proc connCb(server: StreamServer,
            client: StreamTransport) {.async, gcsafe.} =
  trace "incoming connection", address = $client.remoteAddress
  try:
    let t = cast[TcpTransport](server.udata)
    # we don't need result connection in this case
    # as it's added inside connHandler
    discard t.connHandler(client, false)
  except CancelledError as exc:
    debug "Connection setup cancelled", exc = exc.msg
    await client.closeWait()
    raise exc
  except CatchableError as exc:
    debug "Connection setup failed", exc = exc.msg
    await client.closeWait()

proc init*(T: type TcpTransport, flags: set[ServerFlags] = {}): T =
  result = T(flags: flags)
  result.initTransport()

method initTransport*(t: TcpTransport) =
  t.multicodec = multiCodec("tcp")
  inc getTcpTransportTracker().opened

method close*(t: TcpTransport) {.async, gcsafe.} =
  try:
    ## start the transport
    trace "stopping transport"
    await procCall Transport(t).close() # call base

    checkFutures(await allFinished(
      t.clients.mapIt(it.closeWait())))

    # server can be nil
    if not isNil(t.server):
      t.server.stop()
      await t.server.closeWait()

    t.server = nil

    for fut in t.handlers:
      if not fut.finished:
        fut.cancel()

    checkFutures(
      await allFinished(t.handlers))
    t.handlers = @[]

    for fut in t.cleanups:
      if not fut.finished:
        fut.cancel()

    checkFutures(
      await allFinished(t.cleanups))
    t.cleanups = @[]

    trace "transport stopped"
    inc getTcpTransportTracker().closed
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error shutting down tcp transport", exc = exc.msg

method listen*(t: TcpTransport,
               ma: MultiAddress,
               handler: ConnHandler):
               Future[Future[void]] {.async, gcsafe.} =
  discard await procCall Transport(t).listen(ma, handler) # call base

  ## listen on the transport
  t.server = createStreamServer(t.ma, connCb, t.flags, t)
  t.server.start()

  # always get the resolved address in case we're bound to 0.0.0.0:0
  t.ma = MultiAddress.init(t.server.sock.getLocalAddress()).tryGet()
  result = t.server.join()
  trace "started node on", address = t.ma

method dial*(t: TcpTransport,
             address: MultiAddress):
             Future[Connection] {.async, gcsafe.} =
  trace "dialing remote peer", address = $address
  ## dial a peer
  var client: StreamTransport
  try:
    client = await connect(address)
  except CatchableError as exc:
    trace "Exception dialing peer", exc = exc.msg
    if not(isNil(client)):
      await client.closeWait()
    raise exc

  return t.connHandler(client, true)

method handles*(t: TcpTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    result = address.protocols.tryGet().filterIt( it == multiCodec("tcp") ).len > 0
