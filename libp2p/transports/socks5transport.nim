import chronos, chronicles, strutils
import stew/byteutils
import ../multicodec
import transport,
      ../multiaddress,
      ../stream/connection,
      ../stream/chronosstream

type
  Socks5Transport* = ref object of Transport
    transportAddress: TransportAddress

proc new*(
  T: typedesc[Socks5Transport],
  address: string, 
  port: Port): T {.public.} =
  ## Creates a SOCKS5 transport

  T(
    transportAddress: initTAddress(address, port))

proc connHandler*(self: Socks5Transport,
                  client: StreamTransport,
                  dir: Direction): Future[Connection] {.async.} =
  var observedAddr: MultiAddress = MultiAddress()
  try:
    observedAddr = MultiAddress.init(client.remoteAddress).tryGet()
  except CatchableError as exc:
    trace "Failed to create observedAddr", exc = exc.msg
    if not(isNil(client) and client.closed):
      await client.closeWait()
    raise exc

  trace "Handling tcp connection", address = $observedAddr,
                                   dir = $dir,
                                   clients = self.clients[Direction.In].len +
                                   self.clients[Direction.Out].len

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

      #self.clients[dir].keepItIf( it != client )
      await allFuturesThrowing(
        conn.close(), client.closeWait())

      trace "Cleaned up client", addrs = $client.remoteAddress,
                                 conn

    except CatchableError as exc:
      let useExc {.used.} = exc
      debug "Error cleaning up client", errMsg = exc.msg, conn

  #self.clients[dir].add(client)
  asyncSpawn onClose()

  return conn

method dial*(
  self: Socks5Transport,
  hostname: string,
  address: MultiAddress): Future[Connection] {.async, gcsafe.} =
  ## dial a peer
  ##

  trace "Dialing remote peer", address = $address

  let transp = await connect(self.transportAddress)
  var bytesWritten = await transp.write(@[05'u8, 01, 00])
  var resp = await transp.read(2)

  let addressArray = ($address).split('/')
  let addressStr = addressArray[2].split(':')[0] & ".onion"

  let port = string.fromBytes(address.data.buffer[37..38])

  bytesWritten = await transp.write("\x05\x01\x00\x03" & addressStr.len.char & addressStr & port)
  echo bytesWritten
  resp = await transp.read(10)
  echo resp

  return await self.connHandler(transp, Direction.Out)

let s = Socks5Transport.new("127.0.0.1", 9150.Port)
let ma = MultiAddress.init("/onion3/torchdeedp3i2jigzjdmfpn5ttjhthh5wbmda2rr3jvqjg5p77c54dqd:80")
let conn = waitFor s.dial("", ma.tryGet())

let addressStr = "torchdeedp3i2jigzjdmfpn5ttjhthh5wbmda2rr3jvqjg5p77c54dqd.onion"
waitFor conn.write("GET / HTTP/1.1\nHost: $#\n\n" % [addressStr])
var resp: array[1000, byte]
waitFor conn.readExactly(addr resp, 1000)
echo string.fromBytes(resp)




