
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[oids, sequtils]
import chronos, chronicles, strutils
import stew/byteutils
import stew/endians2
import ../multicodec
import transport,
      tcptransport,
      ../wire,
      ../stream/[lpstream, connection, chronosstream],
      ../multiaddress,
      ../upgrademngrs/upgrade

const
  Socks5TransportTrackerName* = "libp2p.tortransport"

  ONIO3_MATCHER = mapAnd(TCP, mapEq("onion3"))

type
  TorTransport* = ref object of Transport
    transportAddress: TransportAddress
    tcpTransport: TcpTransport

proc new*(
  T: typedesc[TorTransport],
  transportAddress: TransportAddress): T {.public.} =
  ## Creates a Tor transport

  T(
    transportAddress: transportAddress,
    tcpTransport: TcpTransport.new(upgrade = Upgrade()))

proc connHandler*(self: TorTransport,
                  client: StreamTransport,
                  dir: Direction): Future[Connection] {.async.} =
  var observedAddr: MultiAddress = MultiAddress()
  try:
    observedAddr = MultiAddress.init("/ip4/0.0.0.0").tryGet()
  except CatchableError as exc:
    trace "Failed to create observedAddr", exc = exc.msg
    if not(isNil(client) and client.closed):
      await client.closeWait()
    raise exc

  trace "Handling tcp connection", address = $observedAddr,
                                   dir = $dir,
                                   clients = self.tcpTransport.clients[Direction.In].len +
                                   self.tcpTransport.clients[Direction.Out].len

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

      self.tcpTransport.clients[dir].keepItIf( it != client )
      await allFuturesThrowing(
        conn.close(), client.closeWait())

      trace "Cleaned up client", addrs = $client.remoteAddress,
                                 conn

    except CatchableError as exc:
      let useExc {.used.} = exc
      debug "Error cleaning up client", errMsg = exc.msg, conn

  self.tcpTransport.clients[dir].add(client)
  asyncSpawn onClose()

  return conn

proc connectToTorServer(transportAddress: TransportAddress): Future[StreamTransport] {.async, gcsafe.} =
  let transp = await connect(transportAddress)
  try:
    var bytesWritten = await transp.write(@[05'u8, 01, 00])
    var resp = await transp.read(2)
    return transp
  except CatchableError as err:
    await transp.closeWait()
    raise err

proc dialPeer(transp: StreamTransport, address: MultiAddress) {.async, gcsafe.} =

  let addressArray = ($address).split('/')
  let addressStr = addressArray[2].split(':')[0] & ".onion"

  # The address field contains a fully-qualified domain name.
  # The first octet of the address field contains the number of octets of name that
  # follow, there is no terminating NUL octet.
  let dstAddr = @(uint8(addressStr.len).toBytes()) & addressStr.toBytes()
  let dstPort = address.data.buffer[37..38]
  let b = @[05'u8, 01, 00, 03] & dstAddr & dstPort

  discard await transp.write(b)
  discard await transp.read(10)

method dial*(
  self: TorTransport,
  hostname: string,
  address: MultiAddress): Future[Connection] {.async, gcsafe.} =
  ## dial a peer
  ##

  trace "Dialing remote peer", address = $address
  let transp = await connectToTorServer(self.transportAddress)

  try:
    await dialPeer(transp, address)
    return await self.connHandler(transp, Direction.Out)
  except CatchableError as err:
    await transp.closeWait()
    raise err

method start*(
  self: TorTransport,
  addrs: seq[MultiAddress]) {.async.} =
  ## listen on the transport
  ##

  #await procCall Transport(self).start(addrs)
  var ipTcpAddrs: seq[MultiAddress]
  var onion3Addrs: seq[MultiAddress]
  for i, ma in addrs:
    if not self.handles(ma):
        trace "Invalid address detected, skipping!", address = ma
        continue
  
    let ipTcp = ma[0..1].get()
    ipTcpAddrs.add(ipTcp)
    let onion3 = ma[multiCodec("onion3")].get()
    onion3Addrs.add(onion3) 

  if len(ipTcpAddrs) != 0 and len(onion3Addrs) != 0:
    await self.tcpTransport.start(ipTcpAddrs)
    self.addrs = onion3Addrs

method accept*(self: TorTransport): Future[Connection] {.async, gcsafe.} =
  ## accept a new TCP connection
  ##
  return await self.tcpTransport.accept()

method stop*(self: TorTransport) {.async, gcsafe.} =
  ## stop the transport
  ##
  await self.tcpTransport.stop()

method handles*(t: TorTransport, address: MultiAddress): bool {.gcsafe.} =  
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return ONIO3_MATCHER.match(address)
