## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

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
  topics = "libp2p tcptransport"

export transport

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

proc setupTcpTransportTracker(): TcpTransportTracker {.gcsafe, raises: [Defect].}

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
  var observedAddr: MultiAddress = MultiAddress()
  try:
    observedAddr = MultiAddress.init(client.remoteAddress).tryGet()
  except CatchableError as exc:
    trace "Connection setup failed", exc = exc.msg
    if not(isNil(client) and client.closed):
      await client.closeWait()
      raise exc

  trace "Handling tcp connection", address = $observedAddr,
                                   dir = $dir,
                                   clients = t.clients[Direction.In].len +
                                   t.clients[Direction.Out].len

  let conn = Connection(
    ChronosStream.init(
      client = client,
      dir = dir,
      observedAddr = observedAddr
    ))

  proc onClose() {.async.} =
    try:
      let futs = @[client.join(), conn.join()]
      await futs[0] or futs[1]
      for f in futs:
        if not f.finished: await f.cancelAndWait() # cancel outstanding join()

      trace "Cleaning up client", addrs = $client.remoteAddress,
                                  conn

      t.clients[dir].keepItIf( it != client )
      await allFuturesThrowing(
        conn.close(), client.closeWait())

      trace "Cleaned up client", addrs = $client.remoteAddress,
                                 conn

    except CatchableError as exc:
      let useExc {.used.} = exc
      debug "Error cleaning up client", errMsg = exc.msg, conn

  t.clients[dir].add(client)
  asyncSpawn onClose()

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

  t.server = createStreamServer(
    ma = t.ma,
    flags = t.flags,
    udata = t)

  # always get the resolved address in case we're bound to 0.0.0.0:0
  t.ma = MultiAddress.init(t.server.sock.getLocalAddress()).tryGet()
  t.running = true

  trace "Listening on", address = t.ma

method stop*(t: TcpTransport) {.async, gcsafe.} =
  ## stop the transport
  ##

  t.running = false # mark stopped as soon as possible

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

method accept*(t: TcpTransport): Future[Connection] {.async, gcsafe.} =
  ## accept a new TCP connection
  ##

  if not t.running:
    raise newTransportClosedError()

  try:
    let transp = await t.server.accept()
    return await t.connHandler(transp, Direction.In)
  except TransportOsError as exc:
    # TODO: it doesn't sound like all OS errors
    # can  be ignored, we should re-raise those
    # that can't.
    debug "OS Error", exc = exc.msg
  except TransportTooManyError as exc:
    debug "Too many files opened", exc = exc.msg
  except TransportUseClosedError as exc:
    debug "Server was closed", exc = exc.msg
    raise newTransportClosedError(exc)
  except CatchableError as exc:
    warn "Unexpected error creating connection", exc = exc.msg
    raise exc

method dial*(t: TcpTransport,
             address: MultiAddress):
             Future[Connection] {.async, gcsafe.} =
  ## dial a peer
  ##

  trace "Dialing remote peer", address = $address

  let transp = await connect(address)
  return await t.connHandler(transp, Direction.Out)

method handles*(t: TcpTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return address.protocols
        .get()
        .filterIt(
          it == multiCodec("tcp")
        ).len > 0
