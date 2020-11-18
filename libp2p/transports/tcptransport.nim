## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[oids, sequtils]
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
    clients: array[Direction, seq[StreamTransport]]
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
                  dir: Direction): Future[Connection] {.async.} =
  debug "Handling tcp connection", address = $client.remoteAddress,
                                   dir = $dir,
                                   clients = t.clients[Direction.In].len +
                                   t.clients[Direction.Out].len

  let conn = Connection(
    ChronosStream.init(
      client,
      dir
    ))

  proc onClose() {.async.} =
    try:
      await client.join() or conn.join()
      trace "Cleaning up client", addrs = $client.remoteAddress,
                                  conn

      if not(isNil(conn) and conn.closed()):
        await conn.close()

      t.clients[dir].keepItIf( it != client )
      if not(isNil(client) and client.closed()):
        await client.closeWait()

      trace "Cleaned up client", addrs = $client.remoteAddress,
                                 conn

    except CatchableError as exc:
      let useExc {.used.} = exc
      debug "Error cleaning up client", errMsg = exc.msg, conn

  t.clients[dir].add(client)
  asyncSpawn onClose()

  try:
    conn.observedAddr = MultiAddress.init(client.remoteAddress).tryGet()
  except CatchableError as exc:
    trace "Connection setup failed", exc = exc.msg, conn
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
        t.clients[Direction.In].mapIt(it.closeWait()) &
        t.clients[Direction.Out].mapIt(it.closeWait())))

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
    warn "Too many files opened", exc = exc.msg
  except TransportUseClosedError as exc:
    info "Server was closed", exc = exc.msg
    raise newTransportClosedError(exc)
  except CatchableError as exc:
    trace "Unexpected error creating connection", exc = exc.msg
    raise exc

method accept*(t: TcpTransport): Future[Connection] {.async, gcsafe.} =
  ## accept a new TCP connection
  ##

  if not t.running:
    raise newTransportClosedError()

  withTransportErrors:
    let transp = await t.server.accept()
    return await t.connHandler(transp, Direction.In)

method dial*(t: TcpTransport,
             address: MultiAddress):
             Future[Connection] {.async, gcsafe.} =
  ## dial a peer
  ##

  trace "Dialing remote peer", address = $address

  withTransportErrors:
    let transp = await connect(address)
    return await t.connHandler(transp, Direction.Out)

method handles*(t: TcpTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    return address.protocols
      .tryGet()
      .filterIt( it == multiCodec("tcp") )
      .len > 0
