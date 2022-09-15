
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[oids, sequtils]
import chronos, chronicles, strutils
import stew/byteutils
import ../multicodec
import transport,
      tcptransport,
      ../wire,
      ../stream/[lpstream, connection, chronosstream],
      ../multiaddress,
      ../upgrademngrs/upgrade

const
  Socks5TransportTrackerName* = "libp2p.socks5transport"

type
  Socks5Transport* = ref object of Transport
    transportAddress: TransportAddress
    tcpTransport: TcpTransport

proc new*(
  T: typedesc[Socks5Transport],
  address: string, 
  port: Port): T {.public, raises: [Defect, TransportAddressError]} =
  ## Creates a SOCKS5 transport

  T(
    transportAddress: initTAddress(address, port),
    tcpTransport: TcpTransport.new(upgrade = Upgrade()))

proc connHandler*(self: Socks5Transport,
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

method dial*(
  self: Socks5Transport,
  hostname: string,
  address: MultiAddress): Future[Connection] {.async, gcsafe.} =
  ## dial a peer
  ##

  trace "Dialing remote peer", address = $address
  try:
    let transp = await connect(self.transportAddress)
    var bytesWritten = await transp.write(@[05'u8, 01, 00])
    var resp = await transp.read(2)

    let addressArray = ($address).split('/')
    let addressStr = addressArray[2].split(':')[0] & ".onion"

    let port = string.fromBytes(address.data.buffer[37..38])

    bytesWritten = await transp.write("\x05\x01\x00\x03" & addressStr.len.char & addressStr & port)
    resp = await transp.read(10)
    echo resp

    return await self.connHandler(transp, Direction.Out)
  except CatchableError as err:
    await transp.closeWait()
    raise err

method start*(
  self: Socks5Transport,
  addrs: seq[MultiAddress]) {.async.} =
  ## listen on the transport
  ##

  await self.tcpTransport.start(addrs)

method accept*(self: Socks5Transport): Future[Connection] {.async, gcsafe.} =
  ## accept a new TCP connection
  ##
  return await self.tcpTransport.accept()

method stop*(self: Socks5Transport) {.async, gcsafe.} =
  ## stop the transport
  ##
  await self.tcpTransport.stop()












