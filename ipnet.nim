import endians, strutils
import chronos

type
  IpMask* = object
    case family*: AddressFamily
    of AddressFamily.None, AddressFamily.Unix:
      discard
    of AddressFamily.IPv4:
      mask4*: uint32
    of AddressFamily.IPv6:
      mask6*: array[2, uint64]

  IpNet* = object
    host*: TransportAddress
    mask*: IpMask

proc toNetworkOrder(mask: IpMask): IpMask {.inline.} =
  ## Converts ``mask`` from host order (which can be big/little-endian) to
  ## network order (which is big-endian) representation.
  result = IpMask(family: mask.family)
  if mask.family == AddressFamily.IPv4:
    bigEndian32(cast[pointer](addr result.mask4),
                cast[pointer](unsafeAddr mask.mask4))
  elif mask.family == AddressFamily.IPv6:
    bigEndian64(cast[pointer](addr result.mask6[0]),
                cast[pointer](unsafeAddr mask.mask6[0]))
    bigEndian64(cast[pointer](addr result.mask6[1]),
                cast[pointer](unsafeAddr mask.mask6[1]))

proc toHostOrder(mask: IpMask): IpMask {.inline.} =
  ## Converts ``mask`` from network order (which is big-endian) back to
  ## host representation (which can be big/little-endian).
  when system.cpuEndian == bigEndian:
    result = mask
  else:
    result = IpMask(family: mask.family)
    if mask.family == AddressFamily.IPv4:
      swapEndian32(cast[pointer](addr result.mask4),
                   cast[pointer](unsafeAddr mask.mask4))
    elif mask.family == AddressFamily.IPv6:
      swapEndian64(cast[pointer](addr result.mask6[0]),
                   cast[pointer](unsafeAddr mask.mask6[0]))
      swapEndian64(cast[pointer](addr result.mask6[1]),
                   cast[pointer](unsafeAddr mask.mask6[1]))

proc init*(t: typedesc[IpMask], family: AddressFamily, prefix: int): IpMask =
  ## Initialize mask of IP family ``family`` from prefix length ``prefix``.
  ##
  ## For IPv4 mask, if ``prefix`` is ``0`` or more then ``32`` it will be set
  ## to ``32``.
  ##
  ## For IPv6 mask, if ``prefix`` is ``0`` or more then ``128`` it will be set
  ## to ``128``.
  if family == AddressFamily.IPv4:
    result = IpMask(family: AddressFamily.IPv4)
    result.mask4 = 0xFFFF_FFFF'u32
    if prefix > 0 and prefix < 32:
      result.mask4 = 0xFFFF_FFFF'u32
      result.mask4 = cast[uint32](result.mask4 shl (32 - prefix))
  elif family == AddressFamily.IPv6:
    result = IpMask(family: AddressFamily.IPv6)
    if prefix >= 128 or prefix <= 0:
      result.mask6[0] = 0xFFFF_FFFF_FFFF_FFFF'u64
      result.mask6[1] = 0xFFFF_FFFF_FFFF_FFFF'u64
    else:
      result.mask6[0] = 0xFFFF_FFFF_FFFF_FFFF'u64
      if prefix > 64:
        result.mask6[1] = 0xFFFF_FFFF_FFFF_FFFF'u64
        result.mask6[1] = result.mask6[1] shl (128 - prefix)
      elif prefix == 64:
        result.mask6[1] = 0x00'u64
      else:
        result.mask6[0] = result.mask6[0] shl (64 - prefix)
        result.mask6[1] = 0x00'u64
  result = result.toNetworkOrder()

proc init*(t: typedesc[IpMask], netmask: TransportAddress): IpMask =
  ## Initialize network mask using address ``netmask``.
  if netmask.family == AddressFamily.IPv4:
    result.family = netmask.family
    result.mask4 = cast[ptr uint32](unsafeAddr netmask.address_v4[0])[]
  elif netmask.family == AddressFamily.IPv6:
    result.family = netmask.family
    result.mask6[0] = cast[ptr uint64](unsafeAddr netmask.address_v6[0])[]
    result.mask6[1] = cast[ptr uint64](unsafeAddr netmask.address_v6[8])[]

proc init*(t: typedesc[IpMask], netmask: string): IpMask =
  ## Initialize network mask using IPv4 or IPv6 address in text representation
  ## ``netmask``.
  ##
  ## If ``netmask`` address string is invalid, result IpMask.family will be
  ## set to ``AddressFamily.None``.
  try:
    var ip = parseIpAddress(netmask)
    var tip = initTAddress(ip, Port(0))
    result = t.init(tip)
  except ValueError:
    discard

proc toIPv6*(address: TransportAddress): TransportAddress =
  ## Map IPv4 ``address`` to IPv6 address.
  ##
  ## If ``address`` is IPv4 address then it will be mapped as:
  ## <80 bits of zeros> + <16 bits of ones> + <32-bit IPv4 address>.
  ##
  ## If ``address`` is IPv6 address it will be returned without any changes.
  if address.family == AddressFamily.IPv4:
    result = TransportAddress(family: AddressFamily.IPv6)
    result.address_v6[10] = 0xFF'u8
    result.address_v6[11] = 0xFF'u8
    let data = cast[ptr uint32](unsafeAddr address.address_v4[0])[]
    cast[ptr uint32](addr result.address_v6[12])[] = data
  elif address.family == AddressFamily.IPv6:
    result = address

proc isV4Mapped*(address: TransportAddress): bool =
  ## Returns ``true`` if ``address`` is (IPv4 to IPv6) mapped address, e.g.
  ## 0000:0000:0000:0000:0000:FFFF:xxxx:xxxx
  ##
  ## Procedure returns ``false`` if ``address`` family is IPv4.
  if address.family == AddressFamily.IPv6:
    let data0 = cast[ptr uint64](unsafeAddr address.address_v6[0])[]
    let data1 = cast[ptr uint16](unsafeAddr address.address_v6[8])[]
    let data2 = cast[ptr uint16](unsafeAddr address.address_v6[10])[]
    result = (data0 == 0'u64) and (data1 == 0x00'u16) and (data2 == 0xFFFF'u16)

proc toIPv4*(address: TransportAddress): TransportAddress =
  ## Get IPv4 from (IPv4 to IPv6) mapped address.
  ##
  ## If ``address`` is IPv4 address it will be returned without any changes.
  ##
  ## If ``address`` is not IPv4 to IPv6 mapped address, then result family will
  ## be set to AddressFamily.None.
  if address.family == AddressFamily.IPv6:
    if isV4Mapped(address):
      result = TransportAddress(family: AddressFamily.IPv4)
      let data = cast[ptr uint32](unsafeAddr address.address_v6[12])[]
      cast[ptr uint32](addr result.address_v4[0])[] = data
  elif address.family == AddressFamily.IPv4:
    result = address

proc mask*(a: TransportAddress, m: IpMask): TransportAddress =
  ## Apply IP mask ``m`` to address ``a`` and return result address.
  ##
  ## If ``a`` family is IPv4 and ``m`` family is IPv6, masking is still
  ## possible when ``m`` has ``FFFF:FFFF:FFFF:FFFF:FFFF:FFFF`` prefix. Returned
  ## value will be IPv4 address.
  ##
  ## If ``a`` family is IPv6 and ``m`` family is IPv4, masking is still
  ## possible when ``a`` holds (IPv4 to IPv6) mapped address. Returned value
  ## will be IPv6 address.
  ##
  ## If ``a`` family is IPv4 and ``m`` family is IPv4, returned value will be
  ## IPv4 address.
  ##
  ## If ``a`` family is IPv6 and ``m`` family is IPv6, returned value will be
  ## IPv6 address.
  ##
  ## In all other cases returned address will have ``AddressFamily.None``.
  if a.family == AddressFamily.IPv4 and m.family == AddressFamily.IPv6:
    if (m.mask6[0] == 0xFFFF_FFFF_FFFF_FFFF'u64) and
       (m.mask6[1] and 0xFFFF_FFFF'u64) == 0xFFFF_FFFF'u64:
      result = TransportAddress(family: a.family)
      let mask = cast[uint32](m.mask6[1] shr 32)
      let data = cast[ptr uint32](unsafeAddr a.address_v4[0])[]
      cast[ptr uint32](addr result.address_v4[0])[] = data and mask
      result.port = a.port
  elif a.family == AddressFamily.IPv6 and m.family == AddressFamily.IPv4:
    var ip = a.toIPv4()
    if ip.family == AddressFamily.IPv4:
      let data = cast[ptr uint32](addr ip.address_v4[0])[]
      cast[ptr uint32](addr ip.address_v4[0])[] = data and m.mask4
      result = ip.toIPv6()
      result.port = a.port
  elif a.family == AddressFamily.IPv4 and m.family == AddressFamily.IPv4:
    result = TransportAddress(family: AddressFamily.IPv4)
    let data = cast[ptr uint32](unsafeAddr a.address_v4[0])[]
    cast[ptr uint32](addr result.address_v4[0])[] = data and m.mask4
    result.port = a.port
  elif a.family == AddressFamily.IPv6 and m.family == AddressFamily.IPv6:
    result = TransportAddress(family: AddressFamily.IPv6)
    let data0 = cast[ptr uint64](unsafeAddr a.address_v6[0])[]
    let data1 = cast[ptr uint64](unsafeAddr a.address_v6[8])[]
    cast[ptr uint64](addr result.address_v6[0])[] = data0 and m.mask6[0]
    cast[ptr uint64](addr result.address_v6[8])[] = data1 and m.mask6[1]
    result.port = a.port

proc prefix*(mask: IpMask): int =
  ## Returns number of bits set `1` in IP mask ``mask``.
  var hmask = mask.toHostOrder()
  if hmask.family == AddressFamily.IPv4:
    var n = hmask.mask4
    while n != 0:
      n = n shl 1
      inc(result)
  elif hmask.family == AddressFamily.IPv6:
    if hmask.mask6[0] == 0xFFFF_FFFF_FFFF_FFFF'u64:
      result += 64
      if hmask.mask6[1] == 0xFFFF_FFFF_FFFF_FFFF'u64:
        result += 64:
      else:
        var n = hmask.mask6[1]
        while n != 0:
          n = n shl 1
          inc(result)
    else:
      var n = hmask.mask6[0]
      while n != 0:
        n = n shl 1
        inc(result)

proc subnetMask*(mask: IpMask): TransportAddress =
  ## Returns TransportAddress representation of IP mask ``mask``.
  result = TransportAddress(family: mask.family)
  if mask.family == AddressFamily.IPv4:
    cast[ptr uint32](addr result.address_v4[0])[] = mask.mask4
  elif mask.family == AddressFamily.IPv6:
    cast[ptr uint64](addr result.address_v6[0])[] = mask.mask6[0]
    cast[ptr uint64](addr result.address_v6[8])[] = mask.mask6[1]

proc `$`*(mask: IpMask): string =
  ## Returns hexadecimal string representation of IP mask ``mask``.
  var host = mask.toHostOrder()
  result = ""
  if host.family == AddressFamily.IPv4:
    result = "0x"
    var n = 32
    var m = host.mask4
    while n > 0:
      n -= 4
      var c = cast[int]((m shr n) and 0x0F)
      if c < 10:
        result.add(chr(ord('0') + c))
      else:
        result.add(chr(ord('A') + (c - 10)))
  elif host.family == AddressFamily.IPv6:
    result = "0x"
    for i in 0..1:
      var n = 64
      var m = host.mask6[i]
      while n > 0:
        n -= 4
        var c = cast[int]((m shr n) and 0x0F)
        if c < 10:
          result.add(chr(ord('0') + c))
        else:
          result.add(chr(ord('A') + (c - 10)))

proc init*(t: typedesc[IpNet], host: TransportAddress,
           prefix: int): IpNet {.inline.} =
  ## Initialize IP Network using host address ``host`` and prefix length
  ## ``prefix``.
  result.mask = IpMask.init(host.family, prefix)
  result.host = mask(host, result.mask)

proc init*(t: typedesc[IpNet], host, mask: TransportAddress): IpNet {.inline.} =
  ## Initialize IP Network using host address ``host`` and network mask
  ## address ``mask``.
  ##
  ## Note that ``host`` and ``mask`` must be from the same IP family.
  if host.family == mask.family:
    result.mask = IpMask.init(mask)
    result.host = mask(host, result.mask)

proc init*(t: typedesc[IpNet], host: TransportAddress,
           mask: IpMask): IpNet {.inline.} =
  ## Initialize IP Network using host address ``host`` and network mask
  ## ``mask``.
  result.mask = mask
  result.host = result.mask(host)

proc init*(t: typedesc[IpNet], network: string): IpNet =
  ## Initialize IP Network from string representation in format
  ## <address>/<prefix length>.
  ##
  ## Not if <prefix length> is not present or its value is bigger then maximum
  ## value (32 for IPv4 and 128 for IPv6), then `/32` and `/128` will be used
  ## as prefix length.
  var parts = network.rsplit("/", maxsplit = 1)
  var host: TransportAddress
  var ipaddr: IpAddress
  var prefix: int
  try:
    ipaddr = parseIpAddress(parts[0])
    if ipaddr.family == IpAddressFamily.IPv4:
      host = TransportAddress(family: AddressFamily.IPv4)
      host.address_v4 = ipaddr.address_v4
      prefix = 32
    elif ipaddr.family == IpAddressFamily.IPv6:
      host = TransportAddress(family: AddressFamily.IPv6)
      host.address_v6 = ipaddr.address_v6
      prefix = 128
    if len(parts) > 1:
      prefix = parseInt(parts[1])
      if ipaddr.family == IpAddressFamily.IPv4 and
         (prefix < 0 or prefix > 32):
        prefix = 32
      elif ipaddr.family == IpAddressFamily.IPv6 and
           (prefix < 0 or prefix > 128):
        prefix = 128
    result = t.init(host, prefix)
  except:
    raise newException(TransportAddressError, "Incorrect address family!")

proc contains*(net: IpNet, address: TransportAddress): bool =
  ## Returns ``true`` if ``address`` belongs to IP Network ``net``
  if net.host.family == address.family:
    var host = mask(address, net.mask)
    result = (net.host == host)

proc broadcast*(net: IpNet): TransportAddress =
  ## Returns broadcast address for IP Network ``net``.
  result = TransportAddress(family: net.host.family)
  if result.family == AddressFamily.IPv4:
    var address = cast[ptr uint32](unsafeAddr net.host.address_v4[0])[]
    var mask = cast[ptr uint32](unsafeAddr net.mask.mask4)[]
    cast[ptr uint32](addr result.address_v4[0])[] = address or (not(mask))
  elif result.family == AddressFamily.IPv6:
    var address0 = cast[ptr uint64](unsafeAddr net.host.address_v6[0])[]
    var address1 = cast[ptr uint64](unsafeAddr net.host.address_v6[8])[]
    var data0 = cast[ptr uint64](unsafeAddr net.mask.mask6[0])[]
    var data1 = cast[ptr uint64](unsafeAddr net.mask.mask6[1])[]
    cast[ptr uint64](addr result.address_v6[0])[] = address0 or (not(data0))
    cast[ptr uint64](addr result.address_v6[8])[] = address1 or (not(data1))

proc subnetMask*(net: IpNet): TransportAddress =
  ## Returns netmask address for IP Network ``net``
  result = TransportAddress(family: net.host.family)
  if result.family == AddressFamily.IPv4:
    var address = cast[ptr uint32](unsafeAddr net.mask.mask4)[]
    cast[ptr uint32](addr result.address_v4[0])[] = address
  elif result.family == AddressFamily.IPv6:
    var address0 = cast[ptr uint64](unsafeAddr net.mask.mask6[0])[]
    var address1 = cast[ptr uint64](unsafeAddr net.mask.mask6[1])[]
    cast[ptr uint64](addr result.address_v6[0])[] = address0
    cast[ptr uint64](addr result.address_v6[8])[] = address1

proc `and`*(address1, address2: TransportAddress): TransportAddress =
  ## Bitwise ``and`` operation for ``address1 and address2``.
  ##
  ## Note only IPv4 and IPv6 addresses are supported. ``address1`` and
  ## ``address2`` must be in equal IP family
  if address1.family == address2.family:
    if address1.family == AddressFamily.IPv4:
      let data1 = cast[ptr uint32](unsafeAddr address1.address_v4[0])[]
      let data2 = cast[ptr uint32](unsafeAddr address2.address_v4[0])[]
      result = TransportAddress(family: address1.family)
      cast[ptr uint32](addr result.address_v4[0])[] = data1 and data2
    elif address1.family == AddressFamily.IPv6:
      let data1 = cast[ptr uint64](unsafeAddr address1.address_v6[0])[]
      let data2 = cast[ptr uint64](unsafeAddr address1.address_v6[8])[]
      let data3 = cast[ptr uint64](unsafeAddr address2.address_v6[0])[]
      let data4 = cast[ptr uint64](unsafeAddr address2.address_v6[8])[]
      result = TransportAddress(family: address1.family)
      cast[ptr uint64](addr result.address_v6[0])[] = data1 and data3
      cast[ptr uint64](addr result.address_v6[8])[] = data2 and data4

proc `or`*(address1, address2: TransportAddress): TransportAddress =
  ## Bitwise ``or`` operation for ``address1 or address2``.
  ##
  ## Note only IPv4 and IPv6 addresses are supported. ``address1`` and
  ## ``address2`` must be in equal IP family
  if address1.family == address2.family:
    if address1.family == AddressFamily.IPv4:
      let data1 = cast[ptr uint32](unsafeAddr address1.address_v4[0])[]
      let data2 = cast[ptr uint32](unsafeAddr address2.address_v4[0])[]
      result = TransportAddress(family: address1.family)
      cast[ptr uint32](addr result.address_v4[0])[] = data1 or data2
    elif address1.family == AddressFamily.IPv6:
      let data1 = cast[ptr uint64](unsafeAddr address1.address_v6[0])[]
      let data2 = cast[ptr uint64](unsafeAddr address1.address_v6[8])[]
      let data3 = cast[ptr uint64](unsafeAddr address2.address_v6[0])[]
      let data4 = cast[ptr uint64](unsafeAddr address2.address_v6[8])[]
      result = TransportAddress(family: address1.family)
      cast[ptr uint64](addr result.address_v6[0])[] = data1 or data3
      cast[ptr uint64](addr result.address_v6[8])[] = data2 or data4

proc `not`*(address: TransportAddress): TransportAddress =
  ## Bitwise ``not`` operation for ``address``.
  if address.family == AddressFamily.IPv4:
    let data = cast[ptr uint32](unsafeAddr address.address_v4[0])[]
    result = TransportAddress(family: address.family)
    cast[ptr uint32](addr result.address_v4[0])[] = not(data)
  elif address.family == AddressFamily.IPv6:
    let data1 = cast[ptr uint64](unsafeAddr address.address_v6[0])[]
    let data2 = cast[ptr uint64](unsafeAddr address.address_v6[8])[]
    result = TransportAddress(family: address.family)
    cast[ptr uint64](addr result.address_v6[0])[] = not(data1)
    cast[ptr uint64](addr result.address_v6[8])[] = not(data2)

proc `+`*(address: TransportAddress, v: uint): TransportAddress =
  ## Add to IPv4/IPv6 transport ``address`` unsigned integer ``v``.
  result = TransportAddress(family: address.family)
  if address.family == AddressFamily.IPv4:
    var a: uint64
    let data = cast[ptr uint32](unsafeAddr address.address_v4[0])
    when system.cpuEndian == bigEndian:
      a = data
    else:
      swapEndian32(addr a, data)
    a = a + v
    bigEndian32(cast[pointer](addr result.address_v4[0]), addr a)
  elif address.family == AddressFamily.IPv6:
    var a1, a2: uint64
    let data1 = cast[ptr uint64](unsafeAddr address.address_v6[0])
    let data2 = cast[ptr uint64](unsafeAddr address.address_v6[8])
    when system.cpuEndian == bigEndian:
      a1 = data1
      a2 = data2
    else:
      swapEndian64(addr a1, data1)
      swapEndian64(addr a2, data2)
    var a3 = a2 + v
    if a3 < a2:
      ## Overflow
      a1 = a1 + 1
    bigEndian64(cast[pointer](addr result.address_v6[0]), addr a1)
    bigEndian64(cast[pointer](addr result.address_v6[8]), addr a3)

proc inc*(address: var TransportAddress, v: uint = 1'u) =
  ## Increment IPv4/IPv6 transport ``address`` by unsigned integer ``v``.
  address = address + v

proc `$`*(net: IpNet): string =
  ## Return string representation of IP network in format:
  ## <IPv4 or IPv6 address>/<prefix length>.
  if net.host.family == AddressFamily.IPv4:
    var a = IpAddress(family: IpAddressFamily.IPv4,
                      address_v4: net.host.address_v4)
    result = $a
    result.add("/")
    result.add($net.mask.prefix())
  elif net.host.family == AddressFamily.IPv6:
    var a = IpAddress(family: IpAddressFamily.IPv6,
                      address_v6: net.host.address_v6)
    result = $a
    result.add("/")
    result.add($net.mask.prefix())

proc isUnspecified*(address: TransportAddress): bool {.inline.} =
  ## Returns ``true`` if ``address`` is not specified yet, e.g. its ``family``
  ## field is not set or equal to ``AddressFamily.None``.
  if address.family == AddressFamily.None:
    result = true

proc isMulticast*(address: TransportAddress): bool =
  ## Returns ``true`` if ``address`` is a multicast address.
  ##
  ## ``IPv4``: 224.0.0.0 - 239.255.255.255
  ##
  ## ``IPv6``: FF00:: - FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF
  if address.family == AddressFamily.IPv4:
    result = ((address.address_v4[0] and 0xF0'u8) == 0xE0'u8)
  elif address.family == AddressFamily.IPv6:
    result = (address.address_v6[0] == 0xFF'u8)

proc isInterfaceLocalMulticast*(address: TransportAddress): bool =
  ## Returns ``true`` if ``address`` is interface local multicast address.
  ##
  ## ``IPv4``:  N/A (always returns ``false``)
  if address.family == AddressFamily.IPv6:
    result = (address.address_v6[0] == 0xFF'u8) and
             ((address.address_v6[1] and 0x0F'u8) == 0x01'u8)

proc isLinkLocalMulticast*(address: TransportAddress): bool =
  ## Returns ``true`` if ``address` is link local multicast address.
  ##
  ## ``IPv4``: 224.0.0.0 - 224.0.0.255
  if address.family == AddressFamily.IPv4:
    result = (address.address_v4[0] == 224'u8) and
             (address.address_v4[1] == 0'u8) and
             (address.address_v4[2] == 0'u8)
  elif address.family == AddressFamily.IPv6:
    result = (address.address_v6[0] == 0xFF'u8) and
             ((address.address_v6[1] and 0x0F'u8) == 0x02'u8)

proc isLoopback*(address: TransportAddress): bool =
  ## Returns ``true`` if ``address`` is loopback address.
  ##
  ## ``IPv4``: 127.0.0.0 - 127.255.255.255
  ##
  ## ``IPv6``: ::1
  if address.family == AddressFamily.IPv4:
    result = (address.address_v4[0] == 127'u8)
  elif address.family == AddressFamily.IPv6:
    var test = 0
    for i in 0..<(len(address.address_v6) - 1):
      test = test or cast[int](address.address_v6[i])
    result = (test == 0) and (address.address_v6[15] == 1'u8)

proc isAnyLocal*(address: TransportAddress): bool =
  ## Returns ``true`` if ``address`` is a wildcard address.
  ##
  ## ``IPv4``: 0.0.0.0
  ##
  ## ``IPv6``: ::
  if address.family == AddressFamily.IPv4:
    let data = cast[ptr uint32](unsafeAddr address.address_v4[0])[]
    result = (data == 0'u32)
  elif address.family == AddressFamily.IPv6:
    let data1 = cast[ptr uint32](unsafeAddr address.address_v6[0])[]
    let data2 = cast[ptr uint32](unsafeAddr address.address_v6[4])[]
    let data3 = cast[ptr uint32](unsafeAddr address.address_v6[8])[]
    let data4 = cast[ptr uint32](unsafeAddr address.address_v6[12])[]
    result = ((data1 or data2 or data3 or data4) == 0'u32)

proc isLinkLocal*(address: TransportAddress): bool =
  ## Returns ``true`` if ``address`` is link local address.
  ##
  ## ``IPv4``: 169.254.0.0 - 169.254.255.255
  ##
  ## ``IPv6``: FE80:: - FEBF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF
  if address.family == AddressFamily.IPv4:
    result = (address.address_v4[0] == 169'u8) and
             (address.address_v4[1] == 254'u8)
  elif address.family == AddressFamily.IPv6:
    result = (address.address_v6[0] == 0xFE'u8) and
             ((address.address_v6[1] and 0xC0'u8) == 0x80'u8)

proc isLinkLocalUnicast*(address: TransportAddress): bool {.inline.} =
  result = isLinkLocal(address)

proc isSiteLocal*(address: TransportAddress): bool =
  ## Returns ``true`` if ``address`` is site local address.
  ##
  ## ``IPv4``: 10.0.0.0 - 10.255.255.255, 172.16.0.0 - 172.31.255.255,
  ##           192.168.0.0 - 192.168.255.255
  ##
  ## ``IPv6``: FEC0:: - FEFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF
  if address.family == AddressFamily.IPv4:
    result = (address.address_v4[0] == 10'u8) or
             ((address.address_v4[0] == 172'u8) and
               ((address.address_v4[1] and 0xF0) == 16)) or
             ((address.address_v4[0] == 192'u8) and
               ((address.address_v4[1] == 168'u8)))
  elif address.family == AddressFamily.IPv6:
    result = (address.address_v6[0] == 0xFE'u8) and
             ((address.address_v6[1] and 0xC0'u8) == 0xC0'u8)

proc isGlobalMulticast*(address: TransportAddress): bool =
  ## Returns ``true`` if the multicast address has global scope.
  ##
  ## ``IPv4``: 224.0.1.0 - 238.255.255.255
  ##
  ## ``IPv6``: FF0E:: - FFFE:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF
  if address.family == AddressFamily.IPv4:
    result = (address.address_v4[0] >= 224'u8) and
             (address.address_v4[0] <= 238'u8) and
             not(
               (address.address_v4[0] == 224'u8) and
               (address.address_v4[1] == 0'u8) and
               (address.address_v4[2] == 0'u8)
             )
  elif address.family == AddressFamily.IPv6:
    result = (address.address_v6[0] == 0xFF'u8) and
             ((address.address_v6[1] and 0x0F'u8) == 0x0E'u8)

when isMainModule:
  var MaskVectors = [
    ["192.168.1.127:1024", "255.255.255.128", "192.168.1.0:1024"],
    ["192.168.1.127:1024", "255.255.255.192", "192.168.1.64:1024"],
    ["192.168.1.127:1024", "255.255.255.224", "192.168.1.96:1024"],
    ["192.168.1.127:1024", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ff80",
     "192.168.1.0:1024"],
    ["192.168.1.127:1024", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffc0",
     "192.168.1.64:1024"],
    ["192.168.1.127:1024", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffe0",
     "192.168.1.96:1024"],
    ["192.168.1.127:1024", "255.0.255.0", "192.0.1.0:1024"],
    ["[2001:db8::1]:1024", "ffff:ff80::", "[2001:d80::]:1024"],
    ["[2001:db8::1]:1024", "f0f0:0f0f::", "[2000:d08::]:1024"]
  ]
  for item in MaskVectors:
    var a = initTAddress(item[0])
    var m = IpMask.init(item[1])
    var r = a.mask(m)
    echo r
  # var temp = [0'u8, 0, 255, 255, 255, 255, 255, 0]
  # echo toHex(cast[ptr uint64](addr temp[0])[])
  # # {IPv4(192, 168, 1, 127), IPMask(ParseIP("255.255.255.192")), IPv4(192, 168, 1, 64)},
  # echo initTAddress("255.255.255.128", 0).toIPv6()
  # var a = initTAddress("255.255.255.0", 0).toIPv6()
  # echo a
  # var m = IpMask.init(a)
  # var b = initTAddress("192.168.1.127", 0)
  # echo b.mask(m)
  # # echo a.mask(m)
