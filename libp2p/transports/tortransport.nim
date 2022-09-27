
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[oids, sequtils]
import chronos, chronicles, strutils
import stew/[byteutils, endians2, results]
import ../multicodec
import transport,
      tcptransport,
      ../wire,
      ../stream/[lpstream, connection, chronosstream],
      ../multiaddress,
      ../upgrademngrs/upgrade

const
  Socks5TransportTrackerName* = "libp2p.tortransport"

  ONIO3_MATCHER = mapEq("onion3")
  TCP_ONIO3_MATCHER = mapAnd(TCP, ONIO3_MATCHER)

type
  TransportStartError* = object of transport.TransportError

  TorTransport* = ref object of Transport
    transportAddress: TransportAddress
    tcpTransport: TcpTransport

proc new*(
  T: typedesc[TorTransport],
  transportAddress: TransportAddress,
  flags: set[ServerFlags] = {},
  upgrade: Upgrade): T {.public.} =
  ## Creates a Tor transport

  T(
    transportAddress: transportAddress,
    upgrader: upgrade,
    tcpTransport: TcpTransport.new(flags, upgrade))

proc connectToTorServer(transportAddress: TransportAddress): Future[StreamTransport] {.async, gcsafe.} =
  let transp = await connect(transportAddress)
  try:
    discard await transp.write(@[05'u8, 01, 00])
    discard await transp.read(2)
    return transp
  except CatchableError as err:
    await transp.closeWait()
    raise err

proc readServerReply(transp: StreamTransport) {.async, gcsafe.} =
  ## The specification for this code is defined on [link text](https://www.rfc-editor.org/rfc/rfc1928#section-5)
  ## and [link text](https://www.rfc-editor.org/rfc/rfc1928#section-6).
  let portNumOctets = 2
  let ipV4NumOctets = 4
  let ipV6NumOctets = 16
  let firstFourOctets = await transp.read(4)
  let atyp = firstFourOctets[3]
  case atyp:
    of 0x01:
      discard await transp.read(ipV4NumOctets + portNumOctets)
    of 0x03:
      let fqdnNumOctets = await transp.read(1)
      discard await transp.read(int(uint8.fromBytes(fqdnNumOctets)) + portNumOctets)
    else:
      discard await transp.read(ipV6NumOctets + portNumOctets)

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
  await readServerReply(transp)

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
    return await self.tcpTransport.connHandler(transp, Opt.none(MultiAddress), Direction.Out)
  except CatchableError as err:
    await transp.closeWait()
    raise err

method start*(
  self: TorTransport,
  addrs: seq[MultiAddress]) {.async.} =
  ## listen on the transport
  ##

  var ipTcpAddrs: seq[MultiAddress]
  var onion3Addrs: seq[MultiAddress]
  for i, ma in addrs:
    if not TCP_ONIO3_MATCHER.match(ma):
        warn "Invalid address detected, skipping!", address = ma
        continue

    let ipTcp = ma[0..1].get()
    ipTcpAddrs.add(ipTcp)
    let onion3 = ma[multiCodec("onion3")].get()
    onion3Addrs.add(onion3)

  if len(ipTcpAddrs) != 0 and len(onion3Addrs) != 0:
    await procCall Transport(self).start(onion3Addrs)
    await self.tcpTransport.start(ipTcpAddrs)
  else:
    raise newException(TransportStartError, "Tor Transport couldn't start, no supported addr was provided.")

method accept*(self: TorTransport): Future[Connection] {.async, gcsafe.} =
  ## accept a new TCP connection
  ##
  return await self.tcpTransport.accept()

method stop*(self: TorTransport) {.async, gcsafe.} =
  ## stop the transport
  ##
  await procCall Transport(self).stop() # call base
  await self.tcpTransport.stop()

method handles*(t: TorTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return ONIO3_MATCHER.match(address) or TCP_ONIO3_MATCHER.match(address)
