import chronos, libp2p, libp2p/transports/webrtctransport
import stew/byteutils

proc echoHandler(conn: Connection, proto: string) {.async.} =
  defer: await conn.close()
  while true:
    try:
      echo "\e[35;1m => Echo Handler <=\e[0m"
      var xx = newSeq[byte](1024)
      let aa = await conn.readOnce(addr xx[0], 1024)
      xx = xx[0..<aa]
      let msg = string.fromBytes(xx)
      echo " => Echo Handler Receive:  ", msg, " <="
      echo " => Echo Handler Try Send: ", msg & "1", " <="
      await conn.write(msg & "1")
    except CatchableError as e:
      echo " => Echo Handler Error: ", e.msg, " <="
      break

proc main {.async.} =
  let ma = MultiAddress.init("/ip4/127.0.0.1/udp/4242/webrtc-direct/certhash/uEiDDq4_xNyDorZBH3TlGazyJdOWSwvo4PUo5YHFMrvDE8g")
  echo ma
  let switch =
    SwitchBuilder.new()
    .withAddress(ma.tryGet()) #TODO the certhash shouldn't be necessary
    .withRng(crypto.newRng())
    .withMplex()
    .withYamux()
    .withTransport(proc (upgr: Upgrade): Transport = WebRtcTransport.new(upgr))
    .withNoise()
    .build()

  let
    codec = "/echo/1.0.0"
    proto = new LPProtocol
  proto.handler = echoHandler
  proto.codec = codec

  switch.mount(proto)
  await switch.start()
  echo "\e[31;1m", $(switch.peerInfo.addrs[0]), "/p2p/", $(switch.peerInfo.peerId), "\e[0m"
  await sleepAsync(1.hours)

waitFor main()
