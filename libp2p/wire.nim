## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements wire network connection procedures.
import asyncdispatch2
import multiaddress, multicodec

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
        if ma.protoArgument(result.address_v4) == 0:
          raise newException(TransportAddressError, "Incorrect IPv4 address")
        inc(state)
      elif code == multiCodec("ip6"):
        result = TransportAddress(family: AddressFamily.IPv6)
        if ma.protoArgument(result.address_v6) == 0:
          raise newException(TransportAddressError, "Incorrect IPv6 address")
        inc(state)
      elif code == multiCodec("unix"):
        result = TransportAddress(family: AddressFamily.Unix)
        if ma.protoArgument(result.address_un) == 0:
          raise newException(TransportAddressError, "Incorrect Unix address")
        result.port = Port(1)
        break
      else:
        raise newException(TransportAddressError,
                           "Could not initialize address!")
    elif state == 1:
      if code == multiCodec("tcp") or code == multiCodec("udp"):
        if ma.protoArgument(pbuf) == 0:
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
