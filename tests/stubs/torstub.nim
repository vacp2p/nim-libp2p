# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

{.push raises: [].}

import tables
import chronos, stew/[byteutils, endians2, shims/net]
import
  ../../libp2p/[
    stream/connection,
    protocols/connectivity/relay/utils,
    transports/tcptransport,
    transports/tortransport,
    upgrademngrs/upgrade,
    multiaddress,
    errors,
    builders,
  ]

type TorServerStub* = ref object of RootObj
  tcpTransport: TcpTransport
  addrTable: Table[string, string]

proc new*(T: typedesc[TorServerStub]): T {.public.} =
  T(
    tcpTransport: TcpTransport.new(flags = {ReuseAddr}, upgrade = Upgrade()),
    addrTable: initTable[string, string](),
  )

proc registerAddr*(self: TorServerStub, key: string, val: string) =
  self.addrTable[key] = val

proc start*(self: TorServerStub, address: TransportAddress) {.async.} =
  let ma = @[MultiAddress.init(address).tryGet()]

  await self.tcpTransport.start(ma)

  var msg = newSeq[byte](3)
  while self.tcpTransport.running:
    let connSrc = await self.tcpTransport.accept()
    await connSrc.readExactly(addr msg[0], 3)

    await connSrc.write(@[05'u8, 00])

    msg = newSeq[byte](4)
    await connSrc.readExactly(addr msg[0], 4)
    let atyp = msg[3]
    let address =
      case atyp
      of Socks5AddressType.IPv4.byte:
        let n = 4 + 2 # +2 bytes for the port
        msg = newSeq[byte](n)
        await connSrc.readExactly(addr msg[0], n)
        var ip: array[4, byte]
        for i, e in msg[0 ..^ 3]:
          ip[i] = e
        $(ipv4(ip)) & ":" & $(Port(fromBytesBE(uint16, msg[^2 ..^ 1])))
      of Socks5AddressType.IPv6.byte:
        let n = 16 + 2 # +2 bytes for the port
        msg = newSeq[byte](n) # +2 bytes for the port
        await connSrc.readExactly(addr msg[0], n)
        var ip: array[16, byte]
        for i, e in msg[0 ..^ 3]:
          ip[i] = e
        $(ipv6(ip)) & ":" & $(Port(fromBytesBE(uint16, msg[^2 ..^ 1])))
      of Socks5AddressType.FQDN.byte:
        await connSrc.readExactly(addr msg[0], 1)
        let n = int(uint8.fromBytes(msg[0 .. 0])) + 2 # +2 bytes for the port
        msg = newSeq[byte](n)
        await connSrc.readExactly(addr msg[0], n)
        string.fromBytes(msg[0 ..^ 3]) & ":" &
          $(Port(fromBytesBE(uint16, msg[^2 ..^ 1])))
      else:
        raise newException(LPError, "Address not supported")

    let tcpIpAddr = self.addrTable[$(address)]

    await connSrc.write(@[05'u8, 00, 00, 01, 00, 00, 00, 00, 00, 00])

    let connDst =
      await self.tcpTransport.dial("", MultiAddress.init(tcpIpAddr).tryGet())

    await bridge(connSrc, connDst)
    await allFutures(connSrc.close(), connDst.close())

proc stop*(self: TorServerStub) {.async.} =
  await self.tcpTransport.stop()
