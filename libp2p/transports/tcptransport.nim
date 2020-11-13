## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import oids, sequtils
import chronos, chronicles
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
    clients: array[bool, seq[StreamTransport]]
    flags: set[ServerFlags]

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
                  initiator: bool): Future[Connection] {.async.} =
  debug "Handling tcp connection", address = $client.remoteAddress,
                                   initiator = initiator,
                                   clients = t.clients[true].len + t.clients[false].len

  let conn = Connection(
    ChronosStream.init(
      client,
      dir = if initiator:
        Direction.Out
      else:
        Direction.In))

  proc onClose() {.async.} =
    try:
      await client.join() or conn.join()
      trace "Cleaning up client", addrs = $client.remoteAddress,
                                  conn = $conn.oid

      if not(isNil(conn) and conn.closed()):
        await conn.close()

      t.clients[initiator].keepItIf( it != client )
      if not(isNil(client) and client.closed()):
        await client.closeWait()

      trace "Cleaned up client", addrs = $client.remoteAddress,
                                 conn = $conn.oid

    except CatchableError as exc:
      let useExc {.used.} = exc
      debug "Error cleaning up client", errMsg = exc.msg, s = conn

  t.clients[initiator].add(client)
  asyncSpawn onClose()

  try:
    conn.observedAddr = MultiAddress.init(client.remoteAddress).tryGet()
  except CatchableError as exc:
    trace "Connection setup failed", exc = exc.msg
    if not(isNil(client) and client.closed):
      await client.closeWait()

    raise exc

  return conn

proc init*(T: type TcpTransport,
           flags: set[ServerFlags] = {}): T =
  result = T(flags: flags)

  result.initTransport()

method initTransport*(t: TcpTransport) =
  t.multicodec = multiCodec("tcp")
  inc getTcpTransportTracker().opened

method start*(t: TcpTransport, ma: MultiAddress) {.async.} =
  ## listen on the transport
  ##

  if t.running:
    trace "TCP transport already running"
    return

  await procCall Transport(t).start(ma)
  trace "Starting TCP transport"

  t.server = createStreamServer(t.ma, t.flags, t)

  # always get the resolved address in case we're bound to 0.0.0.0:0
  t.ma = MultiAddress.init(t.server.sock.getLocalAddress()).tryGet()
  t.running = true

  trace "Listening on", address = t.ma

method stop*(t: TcpTransport) {.async, gcsafe.} =
  ## stop the transport
  ##

  try:
    trace "Stopping TCP transport"
    await procCall Transport(t).stop() # call base

    checkFutures(
      await allFinished(
        t.clients[true].mapIt(it.closeWait()) &
        t.clients[false].mapIt(it.closeWait())))

    # server can be nil
    if not isNil(t.server):
      await t.server.closeWait()

    t.server = nil
    trace "Transport stopped"
    inc getTcpTransportTracker().closed
  except CatchableError as exc:
    trace "Error shutting down tcp transport", exc = exc.msg
  finally:
    t.running = false

template withTransportErrors(body: untyped): untyped =
  try:
    body
  except TransportTooManyError as exc:
    warn "Could not create new connection, too many files opened", exc = exc.msg
  except TransportUseClosedError as exc:
    info "Server was closed", exc = exc.msg
    raise newTransportClosedError(exc)
  except CancelledError as exc:
    trace "Connection setup canceled", exc = exc.msg
    raise exc
  except CatchableError as exc:
    warn "Could not create new connection, unexpected error", exc = exc.msg
    raise exc

method accept*(t: TcpTransport): Future[Connection] {.async, gcsafe.} =
  ## accept a new TCP connection
  ##

  if not t.running:
    raise newTransportClosedError()

  withTransportErrors:
    let transp = await t.server.accept()
    return await t.connHandler(transp, initiator = false)

method dial*(t: TcpTransport,
             address: MultiAddress):
             Future[Connection] {.async, gcsafe.} =
  ## dial a peer
  ##

  trace "Dialing remote peer", address = $address

  withTransportErrors:
    let transp = await connect(address)
    return await t.connHandler(transp, initiator = true)

method handles*(t: TcpTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    address.protocols.tryGet().filterIt( it == multiCodec("tcp") ).len > 0
  else:
    false
