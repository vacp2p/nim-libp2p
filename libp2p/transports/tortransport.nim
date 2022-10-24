# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Tor transport implementation

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronos, chronicles, strutils
import stew/[byteutils, endians2, results]
import ../multicodec
import transport,
      tcptransport,
      ../stream/[lpstream, connection, chronosstream],
      ../multiaddress,
      ../upgrademngrs/upgrade

const
  Socks5ProtocolVersion = byte(5)
  NMethods = byte(1)

  Onion3Matcher = mapEq("onion3")
  TcpOnion3Matcher = mapAnd(TCP, Onion3Matcher)

type
  TorTransport* = ref object of Transport
    transportAddress: TransportAddress
    tcpTransport: TcpTransport

  Socks5AuthMethod* {.pure.} = enum
    NoAuth = 0
    GSSAPI = 1
    UsernamePassword = 2
    NoAcceptableMethod = 0xff

  Socks5RequestCommand* {.pure.} = enum
    Connect = 1, Bind = 2, UdpAssoc = 3

  Socks5AddressType* {.pure.} = enum
    IPv4 = 1, FQDN = 3, IPv6 = 4

  TransportStartError* = object of transport.TransportError

  Socks5Error* = object of CatchableError
  Socks5AuthFailedError* = object of Socks5Error
  Socks5VersionError* = object of Socks5Error

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

proc handlesDial(address: MultiAddress): bool {.gcsafe.} =
  return Onion3Matcher.match(address)

proc handlesStart(address: MultiAddress): bool {.gcsafe.} =
  return TcpOnion3Matcher.match(address)

proc connectToTorServer(
    transportAddress: TransportAddress): Future[StreamTransport] {.async, gcsafe.} =
  let transp = await connect(transportAddress)
  try:
    discard await transp.write(@[Socks5ProtocolVersion, NMethods, Socks5AuthMethod.NoAuth.byte])
    let serverReply = await transp.read(2)
    let socks5ProtocolVersion = serverReply[0]
    let serverSelectedMethod =serverReply[1]
    if socks5ProtocolVersion != Socks5ProtocolVersion:
      raise newException(Socks5VersionError, "Unsupported socks version")
    if serverSelectedMethod != Socks5AuthMethod.NoAuth.byte:
      raise newException(Socks5AuthFailedError, "Unsupported auth method")
    return transp
  except CatchableError as err:
    await transp.closeWait()
    raise err

proc readServerReply(transp: StreamTransport) {.async, gcsafe.} =
  ## The specification for this code is defined on
  ## [link text](https://www.rfc-editor.org/rfc/rfc1928#section-5)
  ## and [link text](https://www.rfc-editor.org/rfc/rfc1928#section-6).
  let portNumOctets = 2
  let ipV4NumOctets = 4
  let ipV6NumOctets = 16
  let firstFourOctets = await transp.read(4)
  let atyp = firstFourOctets[3]
  case atyp:
    of Socks5AddressType.IPv4.byte:
      discard await transp.read(ipV4NumOctets + portNumOctets)
    of Socks5AddressType.FQDN.byte:
      let fqdnNumOctets = await transp.read(1)
      discard await transp.read(int(uint8.fromBytes(fqdnNumOctets)) + portNumOctets)
    else:
      discard await transp.read(ipV6NumOctets + portNumOctets)

proc dialPeer(
    transp: StreamTransport, address: MultiAddress) {.async, gcsafe.} =

  let addressArray = ($address).split('/')
  let addressStr = addressArray[2].split(':')[0] & ".onion"

  # The address field contains a fully-qualified domain name.
  # The first octet of the address field contains the number of octets of name that
  # follow, there is no terminating NUL octet.
  let dstAddr = @(uint8(addressStr.len).toBytes()) & addressStr.toBytes()
  let dstPort = address.data.buffer[37..38]
  let reserved = byte(0)
  let b = @[
    Socks5ProtocolVersion,
    Socks5RequestCommand.Connect.byte,
    reserved,
    Socks5AddressType.FQDN.byte] & dstAddr & dstPort

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

  var listenAddrs: seq[MultiAddress]
  var onion3Addrs: seq[MultiAddress]
  for i, ma in addrs:
    if not handlesStart(ma):
        warn "Invalid address detected, skipping!", address = ma
        continue

    let listenAddress = ma[0..1].get()
    listenAddrs.add(listenAddress)
    let onion3 = ma[multiCodec("onion3")].get()
    onion3Addrs.add(onion3)

  if len(listenAddrs) != 0 and len(onion3Addrs) != 0:
    await procCall Transport(self).start(onion3Addrs)
    await self.tcpTransport.start(listenAddrs)
  else:
    raise newException(TransportStartError, "Tor Transport couldn't start, no supported addr was provided.")

method accept*(self: TorTransport): Future[Connection] {.async, gcsafe.} =
  ## accept a new Tor connection
  ##
  let conn = await self.tcpTransport.accept()
  conn.observedAddr = Opt.none(MultiAddress)
  return conn

method stop*(self: TorTransport) {.async, gcsafe.} =
  ## stop the transport
  ##
  await procCall Transport(self).stop() # call base
  await self.tcpTransport.stop()

method handles*(t: TorTransport, address: MultiAddress): bool {.gcsafe.} =
  if procCall Transport(t).handles(address):
    if address.protocols.isOk:
      return handlesDial(address) or handlesStart(address)
