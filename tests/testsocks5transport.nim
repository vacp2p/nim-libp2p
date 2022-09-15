{.used.}

import std/strformat
import sequtils
import chronos, stew/byteutils
import ../libp2p/[stream/connection,
                  transports/transport,
                  transports/socks5transport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  wire]

import ./helpers, ./commontransport

suite "SOCKS5 transport":
  teardown:
    checkTrackers()

  asyncTest "test dial":
    let s = Socks5Transport.new("127.0.0.1", 9050.Port)
    let ma = MultiAddress.init("/onion3/torchdeedp3i2jigzjdmfpn5ttjhthh5wbmda2rr3jvqjg5p77c54dqd:80")
    let conn = await s.dial("", ma.tryGet())

    let addressStr = "torchdeedp3i2jigzjdmfpn5ttjhthh5wbmda2rr3jvqjg5p77c54dqd.onion"
    await conn.write(fmt("GET / HTTP/1.1\nHost: {addressStr}\n\n"))
    var resp: array[1000, byte]
    await conn.readExactly(addr resp, 1000)
    await conn.close()
    echo string.fromBytes(resp)

  asyncTest "test start":
    proc a() {.async, raises:[].} =
      let s = Socks5Transport.new("127.0.0.1", 9050.Port)
      let ma = MultiAddress.init("/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80")
      let conn = await s.dial("", ma.tryGet())

      let addressStr = "a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad.onion"
      await conn.write(fmt("GET / HTTP/1.1\nHost: {addressStr}\n\n"))
      var resp: array[5, byte]
      await conn.readExactly(addr resp, 5)
      await conn.close()
      #await s.stop()
      echo string.fromBytes(resp)

    let server = Socks5Transport.new("127.0.0.1", 9150.Port)
    let ma = @[MultiAddress.init("/ip4/127.0.0.1/tcp/8080").tryGet()]
    asyncSpawn server.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await server.accept()
      await conn.write("Hello!")
      await conn.close()

    let handlerWait = acceptHandler()

    await a()

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!
    await server.stop()
