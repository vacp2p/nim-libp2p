# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Tor transport implementation

{.push raises: [].}

import chronos, chronicles, strutils, results
import stew/[byteutils, endians2, objects]
import ../multicodec
import
  transport,
  tcptransport,
  ../switch,
  ../autotls/service,
  ../builders,
  ../stream/[lpstream, connection, chronosstream],
  ../multiaddress,
  ../upgrademngrs/upgrade

const
  IPTcp = mapAnd(IP, mapEq("tcp"))
  IPv4Tcp = mapAnd(IP4, mapEq("tcp"))
  IPv6Tcp = mapAnd(IP6, mapEq("tcp"))
  DnsTcp = mapAnd(DNSANY, mapEq("tcp"))

  Socks5ProtocolVersion = byte(5)
  NMethods = byte(1)

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
    Connect = 1
    Bind = 2
    UdpAssoc = 3

  Socks5AddressType* {.pure.} = enum
    IPv4 = 1
    FQDN = 3
    IPv6 = 4

  Socks5ReplyType* {.pure.} = enum
    Succeeded = (0, "Succeeded")
    ServerFailure = (1, "Server Failure")
    ConnectionNotAllowed = (2, "Connection Not Allowed")
    NetworkUnreachable = (3, "Network Unreachable")
    HostUnreachable = (4, "Host Unreachable")
    ConnectionRefused = (5, "Connection Refused")
    TtlExpired = (6, "Ttl Expired")
    CommandNotSupported = (7, "Command Not Supported")
    AddressTypeNotSupported = (8, "Address Type Not Supported")

  TransportStartError* = object of transport.TransportError

  Socks5Error* = object of CatchableError
  Socks5AuthFailedError* = object of Socks5Error
  Socks5VersionError* = object of Socks5Error
  Socks5ServerReplyError* = object of Socks5Error

proc new*(
    T: typedesc[TorTransport],
    transportAddress: TransportAddress,
    flags: set[ServerFlags] = {},
    upgrade: Upgrade,
): T {.public.} =
  ## Creates a Tor transport

  T(
    transportAddress: transportAddress,
    upgrader: upgrade,
    tcpTransport: TcpTransport.new(flags, upgrade),
  )

proc handlesDial(address: MultiAddress): bool {.gcsafe.} =
  return Onion3.match(address) or TCP.match(address) or DNSANY.match(address)

proc handlesStart(address: MultiAddress): bool {.gcsafe.} =
  return TcpOnion3.match(address)

proc connectToTorServer(
    transportAddress: TransportAddress
): Future[StreamTransport] {.
    async: (
      raises: [
        Socks5VersionError, Socks5AuthFailedError, Socks5ServerReplyError, LPError,
        common.TransportError, CancelledError,
      ]
    )
.} =
  let transp = await connect(transportAddress)
  discard
    await transp.write(@[Socks5ProtocolVersion, NMethods, Socks5AuthMethod.NoAuth.byte])
  let
    serverReply = await transp.read(2)
    socks5ProtocolVersion = serverReply[0]
    serverSelectedMethod = serverReply[1]
  if socks5ProtocolVersion != Socks5ProtocolVersion:
    raise newException(Socks5VersionError, "Unsupported socks version")
  if serverSelectedMethod != Socks5AuthMethod.NoAuth.byte:
    raise newException(Socks5AuthFailedError, "Unsupported auth method")
  return transp

proc readServerReply(
    transp: StreamTransport
) {.
    async: (
      raises: [
        Socks5VersionError, Socks5ServerReplyError, LPError, common.TransportError,
        CancelledError,
      ]
    )
.} =
  ## The specification for this code is defined on
  ## [link text](https://www.rfc-editor.org/rfc/rfc1928#section-5)
  ## and [link text](https://www.rfc-editor.org/rfc/rfc1928#section-6).
  let
    portNumOctets = 2
    ipV4NumOctets = 4
    ipV6NumOctets = 16
    firstFourOctets = await transp.read(4)
    socks5ProtocolVersion = firstFourOctets[0]
    serverReply = firstFourOctets[1]
  if socks5ProtocolVersion != Socks5ProtocolVersion:
    raise newException(Socks5VersionError, "Unsupported socks version")
  if serverReply != Socks5ReplyType.Succeeded.byte:
    var socks5ReplyType: Socks5ReplyType
    if socks5ReplyType.checkedEnumAssign(serverReply):
      raise newException(Socks5ServerReplyError, "Server reply error")
    else:
      raise newException(LPError, "Unexpected server reply")
  let atyp = firstFourOctets[3]
  case atyp
  of Socks5AddressType.IPv4.byte:
    discard await transp.read(ipV4NumOctets + portNumOctets)
  of Socks5AddressType.FQDN.byte:
    let fqdnNumOctets = await transp.read(1)
    discard await transp.read(int(uint8.fromBytes(fqdnNumOctets)) + portNumOctets)
  of Socks5AddressType.IPv6.byte:
    discard await transp.read(ipV6NumOctets + portNumOctets)
  else:
    raise newException(LPError, "Address not supported")

proc parseOnion3(
    address: MultiAddress
): (byte, seq[byte], seq[byte]) {.raises: [LPError].} =
  var addressArray = ($address).split('/')
  if addressArray.len < 2:
    raise newException(LPError, "Onion address not supported")
  addressArray = addressArray[2].split(':')
  if addressArray.len == 0:
    raise newException(LPError, "Onion address not supported")
  let
    addressStr = addressArray[0] & ".onion"
    dstAddr = @(uint8(addressStr.len).toBytes()) & addressStr.toBytes()
    dstPort = address.data.buffer[37 .. 38]
  return (Socks5AddressType.FQDN.byte, dstAddr, dstPort)

proc parseIpTcp(
    address: MultiAddress
): (byte, seq[byte], seq[byte]) {.raises: [LPError].} =
  let (codec, atyp) =
    if IPv4Tcp.match(address):
      (multiCodec("ip4"), Socks5AddressType.IPv4.byte)
    elif IPv6Tcp.match(address):
      (multiCodec("ip6"), Socks5AddressType.IPv6.byte)
    else:
      raise newException(LPError, "IP address not supported")
  let
    dstAddr = address[codec].tryGet().protoArgument().tryGet()
    dstPort = address[multiCodec("tcp")].tryGet().protoArgument().tryGet()
  (atyp, dstAddr, dstPort)

proc parseDnsTcp(
    address: MultiAddress
): (byte, seq[byte], seq[byte]) {.raises: [LPError].} =
  let
    dnsAddress = address[multiCodec("dns")].tryGet().protoArgument().tryGet()
    dstAddr = @(uint8(dnsAddress.len).toBytes()) & dnsAddress
    dstPort = address[multiCodec("tcp")].tryGet().protoArgument().tryGet()
  (Socks5AddressType.FQDN.byte, dstAddr, dstPort)

proc dialPeer(
    transp: StreamTransport, address: MultiAddress
) {.
    async: (
      raises: [
        LPError, common.TransportError, CancelledError, Socks5ServerReplyError,
        Socks5VersionError,
      ]
    )
.} =
  let (atyp, dstAddr, dstPort) =
    if Onion3.match(address):
      parseOnion3(address)
    elif IPTcp.match(address):
      parseIpTcp(address)
    elif DnsTcp.match(address):
      parseDnsTcp(address)
    else:
      raise newException(LPError, "Address not supported")

  let reserved = byte(0)
  let request =
    @[Socks5ProtocolVersion, Socks5RequestCommand.Connect.byte, reserved, atyp] & dstAddr &
    dstPort
  discard await transp.write(request)
  await readServerReply(transp)

method dial*(
    self: TorTransport,
    hostname: string,
    address: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  ## dial a peer
  ##
  if not handlesDial(address):
    raise newException(TransportDialError, "Address not supported")
  trace "Dialing remote peer", address = $address

  var transp: StreamTransport

  try:
    transp = await connectToTorServer(self.transportAddress)
    await dialPeer(transp, address)
    return self.tcpTransport.connHandler(transp, Opt.none(MultiAddress), Direction.Out)
  except CancelledError as e:
    safeCloseWait(transp)
    raise e
  except CatchableError as e:
    safeCloseWait(transp)
    raise newException(
      transport.TransportDialError, "error in dial TorTransport: " & e.msg, e
    )

method start*(
    self: TorTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError]).} =
  ## listen on the transport
  ##

  var listenAddrs: seq[MultiAddress]
  var onion3Addrs: seq[MultiAddress]
  for i, ma in addrs:
    if not handlesStart(ma):
      warn "Invalid address detected, skipping!", address = ma
      continue

    let listenAddress = ma[0 .. 1].tryGet()
    listenAddrs.add(listenAddress)
    let onion3 = ma[multiCodec("onion3")].tryGet()
    onion3Addrs.add(onion3)

  if len(listenAddrs) != 0 and len(onion3Addrs) != 0:
    await procCall Transport(self).start(onion3Addrs)
    await self.tcpTransport.start(listenAddrs)
  else:
    raise newException(
      TransportStartError,
      "Tor Transport couldn't start, no supported addr was provided.",
    )

method accept*(
    self: TorTransport
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  ## accept a new Tor connection
  ##
  let conn = await self.tcpTransport.accept()
  conn.observedAddr = Opt.none(MultiAddress)
  return conn

method stop*(self: TorTransport) {.async: (raises: []).} =
  ## stop the transport
  ##
  await procCall Transport(self).stop() # call base
  await self.tcpTransport.stop()

method handles*(t: TorTransport, address: MultiAddress): bool {.gcsafe, raises: [].} =
  if procCall Transport(t).handles(address):
    return handlesDial(address) or handlesStart(address)

type TorSwitch* = ref object of Switch

proc new*(
    T: typedesc[TorSwitch],
    torServer: TransportAddress,
    rng: ref HmacDrbgContext,
    addresses: seq[MultiAddress] = @[],
    flags: set[ServerFlags] = {},
): TorSwitch {.raises: [LPError], public.} =
  var builder = SwitchBuilder.new().withRng(rng).withTransport(
      proc(upgr: Upgrade, privateKey: PrivateKey, autotls: AutotlsService): Transport =
        TorTransport.new(torServer, flags, upgr)
    )
  if addresses.len != 0:
    builder = builder.withAddresses(addresses)
  let switch = builder.withMplex().withNoise().build()
  let torSwitch = T(
    peerInfo: switch.peerInfo,
    ms: switch.ms,
    transports: switch.transports,
    connManager: switch.connManager,
    peerStore: switch.peerStore,
    dialer: Dialer.new(
      switch.peerInfo.peerId, switch.connManager, switch.peerStore, switch.transports,
      nil,
    ),
    nameResolver: nil,
  )

  torSwitch.connManager.peerStore = switch.peerStore
  return torSwitch

method addTransport*(s: TorSwitch, t: Transport) =
  doAssert(false, "[TorSwitch.addTransport ] abstract method not implemented!")

method getTorTransport*(s: TorSwitch): Transport {.base.} =
  return s.transports[0]
