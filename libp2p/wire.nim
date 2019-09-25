## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements wire network connection procedures.
import chronos
import multiaddress, multicodec

when defined(windows):
  import winlean
else:
  import posix

proc initTAddress*(ma: MultiAddress): TransportAddress =
  ## Initialize ``TransportAddress`` with MultiAddress ``ma``.
  ##
  ## MultiAddress must be wire address, e.g. ``{IP4, IP6, UNIX}/{TCP, UDP}``.
  var state = 0
  var pbuf: array[2, byte]
  for part in ma.items():
    let code = part.protoCode()
    if state == 0:
      if code == multiCodec("ip4"):
        result = TransportAddress(family: AddressFamily.IPv4)
        if part.protoArgument(result.address_v4) == 0:
          raise newException(TransportAddressError, "Incorrect IPv4 address")
        inc(state)
      elif code == multiCodec("ip6"):
        result = TransportAddress(family: AddressFamily.IPv6)
        if part.protoArgument(result.address_v6) == 0:
          raise newException(TransportAddressError, "Incorrect IPv6 address")
        inc(state)
      elif code == multiCodec("unix"):
        result = TransportAddress(family: AddressFamily.Unix)
        if part.protoArgument(result.address_un) == 0:
          raise newException(TransportAddressError, "Incorrect Unix address")
        result.port = Port(1)
        break
      else:
        raise newException(TransportAddressError,
                           "Could not initialize address!")
    elif state == 1:
      if code == multiCodec("tcp") or code == multiCodec("udp"):
        if part.protoArgument(pbuf) == 0:
          raise newException(TransportAddressError, "Incorrect port")
        result.port = Port((cast[uint16](pbuf[0]) shl 8) or
                            cast[uint16](pbuf[1]))
        break
      else:
        raise newException(TransportAddressError,
                           "Could not initialize address!")

proc connect*(ma: MultiAddress, bufferSize = DefaultStreamBufferSize,
              child: StreamTransport = nil): Future[StreamTransport] =
  ## Open new connection to remote peer with address ``ma`` and create
  ## new transport object ``StreamTransport`` for established connection.
  ## ``bufferSize`` is size of internal buffer for transport.

  let address = initTAddress(ma)
  if address.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
    if ma[1].protoCode() != multiCodec("tcp"):
      var retFuture = newFuture[StreamTransport]()
      retFuture.fail(newException(TransportAddressError,
                                  "Incorrect address type!"))
      return retFuture
  result = connect(address, bufferSize, child)

proc createStreamServer*[T](ma: MultiAddress,
                            cbproc: StreamCallback,
                            flags: set[ServerFlags] = {},
                            udata: ref T,
                            sock: AsyncFD = asyncInvalidSocket,
                            backlog: int = 100,
                            bufferSize: int = DefaultStreamBufferSize,
                            child: StreamServer = nil,
                            init: TransportInitCallback = nil): StreamServer =
  ## Create new TCP stream server which bounds to ``ma`` address.
  var address = initTAddress(ma)
  if address.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
    if ma[1].protoCode() != multiCodec("tcp"):
      raise newException(TransportAddressError, "Incorrect address type!")
  result = createStreamServer(address, cbproc, flags, udata, sock, backlog,
                              bufferSize, child, init)

proc createAsyncSocket*(ma: MultiAddress): AsyncFD =
  ## Create new asynchronous socket using MultiAddress' ``ma`` socket type and
  ## protocol information.
  ##
  ## Returns ``asyncInvalidSocket`` on error.
  var
    socktype: SockType = SockType.SOCK_STREAM
    protocol: Protocol = Protocol.IPPROTO_TCP
    address: TransportAddress

  try:
    address = initTAddress(ma)
  except:
    return asyncInvalidSocket

  if address.family in {AddressFamily.IPv4, AddressFamily.IPv6}:
    if ma[1].protoCode() == multiCodec("udp"):
      socktype = SockType.SOCK_DGRAM
      protocol = Protocol.IPPROTO_UDP
    elif ma[1].protoCode() == multiCodec("tcp"):
      socktype = SockType.SOCK_STREAM
      protocol = Protocol.IPPROTO_TCP
  elif address.family in {AddressFamily.Unix}:
    socktype = SockType.SOCK_STREAM
    protocol = cast[Protocol](0)
  else:
    return asyncInvalidSocket
  result = createAsyncSocket(address.getDomain(), socktype, protocol)

proc bindAsyncSocket*(sock: AsyncFD, ma: MultiAddress): bool =
  ## Bind socket ``sock`` to MultiAddress ``ma``.
  var
    saddr: Sockaddr_storage
    slen: SockLen
    address: TransportAddress
  try:
    address = initTAddress(ma)
  except:
    return false
  toSAddr(address, saddr, slen)
  if bindSocket(SocketHandle(sock), cast[ptr SockAddr](addr saddr), slen) == 0:
    result = true
  else:
    result = false

proc getLocalAddress*(sock: AsyncFD): TransportAddress =
  ## Retrieve local socket ``sock`` address.
  var saddr: Sockaddr_storage
  var slen = SockLen(sizeof(Sockaddr_storage))

  if getsockname(SocketHandle(sock), cast[ptr SockAddr](addr saddr),
                 addr slen) == 0:
    fromSAddr(addr saddr, slen, result)

proc toMultiAddr*(address: TransportAddress): MultiAddress = 
  ## Returns string representation of ``address``.
  case address.family
  of AddressFamily.IPv4:
    var a = IpAddress(
      family: IpAddressFamily.IPv4,
      address_v4: address.address_v4
    )
    result = MultiAddress.init(a, Protocol.IPPROTO_TCP, address.port)
  of AddressFamily.IPv6:
    var a = IpAddress(family: IpAddressFamily.IPv6,
                      address_v6: address.address_v6)
    result = MultiAddress.init(a, Protocol.IPPROTO_TCP, address.port)
  else:
    raise newException(TransportAddressError, "Invalid address for transport!")
