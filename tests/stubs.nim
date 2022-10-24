{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import tables
import chronos, stew/[byteutils, endians2]
import ../libp2p/[stream/connection,
                  protocols/connectivity/relay/utils,
                  transports/tcptransport,
                  transports/tortransport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  builders]

const torServer = initTAddress("127.0.0.1", 9050.Port)

type
  TorServerStub* = ref object of RootObj
    tcpTransport: TcpTransport
    addrTable: Table[string, string]

proc new*(
  T: typedesc[TorServerStub]): T {.public.} =

  T(
    tcpTransport: TcpTransport.new(flags = {ReuseAddr}, upgrade = Upgrade()),
    addrTable: initTable[string, string]())

proc registerOnionAddr*(self: TorServerStub, key: string, val: string) =
  self.addrTable[key] = val

proc start*(self: TorServerStub) {.async.} =
  let ma = @[MultiAddress.init(torServer).tryGet()]

  await self.tcpTransport.start(ma)

  var msg = newSeq[byte](3)
  while self.tcpTransport.running:
    let connSrc = await self.tcpTransport.accept()
    await connSrc.readExactly(addr msg[0], 3)

    await connSrc.write(@[05'u8, 00])

    msg = newSeq[byte](5)
    await connSrc.readExactly(addr msg[0], 5)
    let n = int(uint8.fromBytes(msg[4..4])) + 2 # +2 bytes for the port
    msg = newSeq[byte](n)
    await connSrc.readExactly(addr msg[0], n)

    let onionAddr = string.fromBytes(msg[0..^3]) # ignore the port

    let tcpIpAddr = self.addrTable[$(onionAddr)]

    await connSrc.write(@[05'u8, 00, 00, 01, 00, 00, 00, 00, 00, 00])

    let connDst = await self.tcpTransport.dial("", MultiAddress.init(tcpIpAddr).tryGet())

    await bridge(connSrc, connDst)
    await allFutures(connSrc.close(), connDst.close())


proc stop*(self: TorServerStub) {.async.} =
  await self.tcpTransport.stop()