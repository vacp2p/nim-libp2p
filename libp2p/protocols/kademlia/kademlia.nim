import chronos
import chronicles
import ../../peerid
import ./consts
import ./routingtable
import ../protocol
import ../../switch
import ./protobuf
import ../../utils/heartbeat

logScope:
  topics = "kad-dht"

type KadDHT* = ref object of LPProtocol
  switch: Switch
  rng: ref HmacDrbgContext
  rtable*: RoutingTable
  maintenanceLoop: Future[void]

proc maintainBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh buckets", 10.minutes:
    debug "TODO: implement bucket maintenance"

proc new*(
    T: typedesc[KadDHT], switch: Switch, rng: ref HmacDrbgContext = newRng()
): T {.raises: [].} =
  var rtable = RoutingTable.init(switch.peerInfo.peerId)
  let kad = T(rng: rng, switch: switch, rtable: rtable)

  kad.codec = KadCodec
  kad.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      while not conn.atEof:
        let
          buf = await conn.readLp(4096)
          msg = Message.decode(buf).tryGet()

        # TODO: handle msg.msgType
    except CancelledError as exc:
      raise exc
    except CatchableError:
      error "could not handle request",
        peerId = conn.PeerId, err = getCurrentExceptionMsg()
    finally:
      await conn.close()

  return kad

method start*(
    kad: KadDHT
): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  if kad.started:
    warn "Starting kad-dht twice"
    return fut

  kad.maintenanceLoop = kad.maintainBuckets()
  kad.started = true

  info "kad-dht started"

  fut

method stop*(kad: KadDHT): Future[void] {.async: (raises: [], raw: true).} =
  if not kad.started:
    return

  kad.started = false
  kad.maintenanceLoop.cancelSoon()
  kad.maintenanceLoop = nil
  return
