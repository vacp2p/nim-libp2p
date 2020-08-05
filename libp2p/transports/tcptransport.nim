## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import oids
import chronos, chronicles, sequtils, sets
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
  MaxTCPConnections* = 50

type
  TooManyConnections* = object of CatchableError

  TcpTransport* = ref object of Transport
    server*: StreamServer
    conns: HashSet[ChronosStream]
    flags: set[ServerFlags]
    cleanups*: seq[Future[void]]
    handlers*: seq[Future[void]]
    maxIncoming: int
    maxOutgoing: int

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

proc newTooManyConnections(): ref TooManyConnections =
  newException(TooManyConnections, "too many inbound connections")

proc cleanup(t: TcpTransport, conn: ChronosStream) {.async.} =
  try:
    await conn.closeEvent.wait()
    trace "cleaning up socket", addrs = $conn.client.remoteAddress,
                                connoid = $conn.oid
    if not(isNil(conn)):
      await conn.close()

    t.conns.excl(conn)

    let inLen = toSeq(t.conns).filterIt( it.dir == Direction.In ).len
    if  inLen < t.maxIncoming:
      if not isNil(t.server):
        trace "restarting accept loop", limit = inLen
        t.server.start()

  except CatchableError as exc:
    trace "error cleaning up socket", exc = exc.msg

proc connHandler*(t: TcpTransport,
                  client: StreamTransport,
                  initiator: bool): Connection =
  trace "handling connection", address = $client.remoteAddress
  let stream = ChronosStream.init(client,
                                  dir = if initiator: Direction.Out
                                  else: Direction.In)

  let conn = Connection(stream)
  stream.observedAddr = MultiAddress.init(client.remoteAddress).tryGet()
  if not initiator:
    if not isNil(t.handler):
      t.handlers &= t.handler(conn)

  proc cleanup() {.async.} =
    try:
      await client.join()
      trace "cleaning up client", addrs = $client.remoteAddress, connoid = $conn.oid
      if not(isNil(conn)):
        await conn.close()
      t.clients.keepItIf(it != client)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "error cleaning up client", exc = exc.msg

  t.clients.add(client)
  asyncCheck cleanup()
  result = conn

proc connCb(server: StreamServer,
            client: StreamTransport) {.async, gcsafe.} =
  trace "incoming connection", address = $client.remoteAddress
  try:
    let t = cast[TcpTransport](server.udata)
    let inLen = toSeq(t.conns).filterIt( it.dir == Direction.In ).len
    if  inLen + 1 >= t.maxIncoming:
      trace "connection limit reached", limit = t.maxIncoming,
                                        dir = $Direction.In
      server.stop()
      await client.closeWait()
      return

    # we don't need result connection in this case
    # as it's added inside connHandler
    discard connHandler(t, client, false)

  except CancelledError as exc:
    raise exc
  except CatchableError as err:
    debug "Connection setup failed", err = err.msg
    client.close()

proc init*(T: type TcpTransport,
           flags: set[ServerFlags] = {},
           maxIncoming, maxOutgoing = MaxTCPConnections): T =
  result = T(flags: flags,
             maxIncoming: maxIncoming,
             maxOutgoing: maxOutgoing)

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
      toSeq(t.conns).mapIt(it.client.closeWait())))

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
  t.server = createStreamServer(
    t.ma,
    connCb,
    t.flags,
    t,
    backlog = t.maxIncoming)

  t.server.start()

  # always get the resolved address in case we're bound to 0.0.0.0:0
  t.ma = MultiAddress.init(t.server.sock.getLocalAddress()).tryGet()
  result = t.server.join()
  trace "started node on", address = t.ma

method dial*(t: TcpTransport,
             address: MultiAddress):
             Future[Connection] {.async, gcsafe.} =
  trace "dialing remote peer", address = $address

  let outLen = toSeq(t.conns).filterIt( it.dir == Direction.Out ).len
  if outLen + 1 >= t.maxOutgoing:
    trace "connection limit reached", limit = t.maxOutgoing,
                                      dir = $Direction.Out
    raise newTooManyConnections()

  ## dial a peer
  let client = await connect(address)
  return t.connHandler(client, true)

method handles*(t: TcpTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    return (address.protocols.tryGet()
      .filterIt( it == multiCodec("tcp") ).len > 0)
