## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

## This module implements wire network connection procedures.
import std/[sugar, sets, sequtils]
import chronos, stew/endians2, stew/byteutils, chronicles
import multiaddress, multicodec, errors

when defined(windows):
  import winlean
else:
  import posix

logScope:
  topics = "libp2p wire"

const
  TRANSPMA* = mapOr(
    UDP,
    TCP,
    UNIX,
  )

  RTRANSPMA* = mapOr(
    TCP,
    UNIX
  )

proc resolveDnsAddress(ma: MultiAddress, domain: Domain = Domain.AF_UNSPEC, prefix = ""): Future[seq[MultiAddress]] {.async, raises: [Defect, MaError, TransportAddressError].} =
  var
    dnsbuf: array[256, byte]
    pbuf: array[2, byte]

  if ma[0].tryGet().protoArgument(dnsbuf).tryGet() == 0:
    raise newException(MaError, "Invalid DNS format")
  let dnsval = string.fromBytes(dnsbuf)

  if ma[1].tryGet().protoArgument(pbuf).tryGet() == 0:
    raise newException(MaError, "Incorrect port number")
  let
    port = Port(fromBytesBE(uint16, pbuf))
    resolvedAddresses = resolveTAddress(prefix & dnsval, port, domain)
 
  var addressSuffix = ma
  return collect(newSeqOfCap(4)):
    for address in resolvedAddresses:
      var createdAddress = MultiAddress.init(address).tryGet()[0].tryGet()
      for part in ma:
        if DNS.match(part.get()): continue
        createdAddress &= part.tryGet()
      createdAddress

proc resolveMAddresses*(addrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.async.} =
  var res = initOrderedSet[MultiAddress](addrs.len)

  for address in addrs:
    if not DNS.matchPartial(address):
      res.incl(address)
    else:
      let code = address[0].get().protoCode().get()
      let seq = case code:
        of multiCodec("dns"):
          await resolveDnsAddress(address)
        of multiCodec("dns4"):
          await resolveDnsAddress(address, Domain.AF_INET)
        of multiCodec("dns6"):
          await resolveDnsAddress(address, Domain.AF_INET6)
        of multiCodec("dnsaddr"):
          await resolveDnsAddress(address, prefix="_dnsaddr.")
        else:
          @[address]
      for ad in seq:
        res.incl(ad)
  return res.toSeq

proc initTAddress*(ma: MultiAddress): MaResult[TransportAddress] =
  ## Initialize ``TransportAddress`` with MultiAddress ``ma``.
  ##
  ## MultiAddress must be wire address, e.g. ``{DNS, IP4, IP6, UNIX}/{TCP, UDP}``.
  ##

  if TRANSPMA.match(ma):
    var pbuf: array[2, byte]
    let code = (?(?ma[0]).protoCode())
    if code == multiCodec("unix"):
      var res = TransportAddress(family: AddressFamily.Unix)
      if (?(?ma[0]).protoArgument(res.address_un)) == 0:
        err("Incorrect Unix domain address")
      else:
        res.port = Port(1)
        ok(res)
    elif code == multiCodec("ip4"):
      var res = TransportAddress(family: AddressFamily.IPv4)
      if (?(?ma[0]).protoArgument(res.address_v4)) == 0:
        err("Incorrect IPv4 address")
      else:
        if (?(?ma[1]).protoArgument(pbuf)) == 0:
          err("Incorrect port number")
        else:
          res.port = Port(fromBytesBE(uint16, pbuf))
          ok(res)
    elif code == multiCodec("ip6"):
      var res = TransportAddress(family: AddressFamily.IPv6)
      if (?(?ma[0]).protoArgument(res.address_v6)) == 0:
        err("Incorrect IPv6 address")
      else:
        if (?(?ma[1]).protoArgument(pbuf)) == 0:
          err("Incorrect port number")
        else:
          res.port = Port(fromBytesBE(uint16, pbuf))
          ok(res)
    else:
      err("MultiAddress must be wire address (tcp, udp or unix)")
  else:
    err("MultiAddress must be wire address (tcp, udp or unix)")

proc connect*(
  ma: MultiAddress,
  bufferSize = DefaultStreamBufferSize,
  child: StreamTransport = nil): Future[StreamTransport]
  {.raises: [Defect, LPError, MaInvalidAddress], async.} =
  ## Open new connection to remote peer with address ``ma`` and create
  ## new transport object ``StreamTransport`` for established connection.
  ## ``bufferSize`` is size of internal buffer for transport.
  ##

  if not(RTRANSPMA.match(ma)):
    raise newException(MaInvalidAddress, "Incorrect or unsupported address!")

  let addressesResolved = await resolveMAddresses(@[ma])
  var lastException: ref CatchableError = newException(MaInvalidAddress, "No address resolved")
  for address in addressesResolved:
    try:
      return await connect(initTAddress(address).tryGet(), bufferSize, child)
    except CatchableError as exc:
      debug "Connect failed", msg = exc.msg
      lastException = exc
      continue #try next
  raise lastException

proc createStreamServer*[T](ma: MultiAddress,
                            cbproc: StreamCallback,
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = 100,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil): StreamServer
                            {.raises: [Defect, LPError, MaInvalidAddress, CatchableError].} =
  ## Create new TCP stream server which bounds to ``ma`` address.
  if not(RTRANSPMA.match(ma)):
    raise newException(MaInvalidAddress, "Incorrect or unsupported address!")

  let addressesResolved = waitFor resolveMAddresses(@[ma])
  var lastException: ref CatchableError = newException(MaInvalidAddress, "No address resolved")
  for address in addressesResolved:
    try:
      return createStreamServer(
        initTAddress(address).tryGet(),
        cbproc,
        flags,
        udata,
        sock,
        backlog,
        bufferSize,
        child,
        init)
    except CatchableError as exc:
      debug "Connect failed", msg = exc.msg
      lastException = exc
      continue #try next
  raise lastException

proc createStreamServer*[T](ma: MultiAddress,
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = 100,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil): StreamServer
                            {.raises: [Defect, LPError, MaInvalidAddress, CatchableError].} =
  ## Create new TCP stream server which bounds to ``ma`` address.
  ##

  if not(RTRANSPMA.match(ma)):
    raise newException(MaInvalidAddress, "Incorrect or unsupported address!")

  let addressesResolved = waitFor resolveMAddresses(@[ma])
  var lastException: ref CatchableError = newException(MaInvalidAddress, "No address resolved")
  for address in addressesResolved:
    try:
      return createStreamServer(
        initTAddress(address).tryGet(),
        flags,
        udata,
        sock,
        backlog,
        bufferSize,
        child,
        init)
    except CatchableError as exc:
      debug "Connect failed", msg = exc.msg
      lastException = exc
      continue #try next
  raise lastException

proc createAsyncSocket*(ma: MultiAddress): AsyncFD
  {.raises: [Defect, LPError].} =
  ## Create new asynchronous socket using MultiAddress' ``ma`` socket type and
  ## protocol information.
  ##
  ## Returns ``asyncInvalidSocket`` on error.
  ##
  ## Note: This procedure only used in `go-libp2p-daemon` wrapper.
  ##

  var
    socktype: SockType = SockType.SOCK_STREAM
    protocol: Protocol = Protocol.IPPROTO_TCP

  let address = initTAddress(ma).tryGet()
  if address.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
    if ma[1].tryGet().protoCode().tryGet() == multiCodec("udp"):
      socktype = SockType.SOCK_DGRAM
      protocol = Protocol.IPPROTO_UDP
    elif ma[1].tryGet().protoCode().tryGet() == multiCodec("tcp"):
      socktype = SockType.SOCK_STREAM
      protocol = Protocol.IPPROTO_TCP
  elif address.family in {AddressFamily.Unix}:
    socktype = SockType.SOCK_STREAM
    protocol = cast[Protocol](0)
  else:
    return asyncInvalidSocket

  try:
    createAsyncSocket(address.getDomain(), socktype, protocol)
  except CatchableError as exc:
    raise newException(LPError, exc.msg)

proc bindAsyncSocket*(sock: AsyncFD, ma: MultiAddress): bool
  {.raises: [Defect, LPError].} =
  ## Bind socket ``sock`` to MultiAddress ``ma``.
  ##
  ## Note: This procedure only used in `go-libp2p-daemon` wrapper.
  ##

  var
    saddr: Sockaddr_storage
    slen: SockLen

  let address = initTAddress(ma).tryGet()
  toSAddr(address, saddr, slen)
  if bindSocket(SocketHandle(sock), cast[ptr SockAddr](addr saddr),
                slen) == 0:
    result = true
  else:
    result = false

proc getLocalAddress*(sock: AsyncFD): TransportAddress =
  ## Retrieve local socket ``sock`` address.
  ##
  ## Note: This procedure only used in `go-libp2p-daemon` wrapper.
  var saddr: Sockaddr_storage
  var slen = SockLen(sizeof(Sockaddr_storage))

  if getsockname(SocketHandle(sock), cast[ptr SockAddr](addr saddr),
                 addr slen) == 0:
    fromSAddr(addr saddr, slen, result)
