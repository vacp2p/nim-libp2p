import unittest, chronos, tables, strutils, os
import libp2p/[switch,
               multistream,
               protocols/identify,
               connection,
               transports/transport,
               transports/tcptransport,
               multiaddress,
               peerinfo,
               crypto/crypto,
               peer,
               peerinfo,
               protocols/protocol,
               muxers/muxer,
               muxers/mplex/mplex,
               muxers/mplex/types,
               protocols/secure/secio,
               protocols/secure/secure,
               standard_setup]

const EchoCodec = "/echo"
type EchoProto = ref object of LPProtocol

proc main(server: bool = false): Future[void] {.async, gcsafe.} =

  proc handler(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      while not conn.isClosed:
        var msg = await conn.readLp()
        echo "RECEIVED ", cast[string](msg)
        await conn.writeLp(msg)
    except:
      echo getCurrentExceptionMsg()

  var switch = newStandardSwitch()
  var awaiters: seq[Future[void]]

  if server:
    let echoProto = new EchoProto
    echoProto.codec = EchoCodec
    echoProto.handler = handler
    switch.mount(echoProto)

  awaiters.add(await switch.start())

  echo "STATS BEFORE CONNECT"
  echo GC_getStatistics()

  echo "listenning on ma: "
  for ma in switch.peerInfo.addrs:
    echo $ma & "/ipfs/" & switch.peerInfo.id

  if not server:
    try:
      echo "remote multiaddr: "
      var remoteMa = stdin.readLine()
      var parts = remoteMa.split("/")
      if parts.len != 7:
        raise newException(Defect, "invalid multiaddr")

      var peerInfo = PeerInfo.init(PeerID.init(parts[^1]), @[MultiAddress.init(remoteMa)])
      while true:
        let conn = await switch.dial(peerInfo, EchoCodec)
        await conn.writeLp("HELLO")
        let msg = await conn.readLp()
        echo "RECEIVED ", cast[string](msg)
        await sleepAsync(2.seconds)
        await switch.disconnect(peerInfo)

    except CatchableError as exc:
      echo "Exception ", exc.msg

  await allFutures(awaiters)

var params = commandLineParams()
var isServer = false
if params.len > 0:
  isServer = parseBool(params[0])

waitFor(main(isServer))
