{.used.}

import std/strformat
import sequtils
import chronos, stew/byteutils
import ../libp2p/[stream/connection,
                  transports/transport,
                  transports/tortransport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  wire,
                  builders]

import ./helpers, ./commontransport

let torServer = initTAddress("127.0.0.1", 9050.Port)

suite "Tor transport":
  teardown:
    checkTrackers()

  asyncTest "test dial":
    let s = TorTransport.new(transportAddress = torServer, upgrade = Upgrade())
    let ma = MultiAddress.init("/onion3/torchdeedp3i2jigzjdmfpn5ttjhthh5wbmda2rr3jvqjg5p77c54dqd:80")
    let conn = await s.dial("", ma.tryGet())

    let addressStr = "torchdeedp3i2jigzjdmfpn5ttjhthh5wbmda2rr3jvqjg5p77c54dqd.onion"
    await conn.write(fmt("GET / HTTP/1.1\nHost: {addressStr}\n\n"))
    var resp: array[1000, byte]
    await conn.readExactly(addr resp, 1000)
    await conn.close()
    echo string.fromBytes(resp)

  asyncTest "test dial and start":
    proc a() {.async, raises:[].} =
      let s = TorTransport.new(transportAddress = torServer, upgrade = Upgrade())
      let ma = MultiAddress.init("/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80")
      let conn = await s.dial("", ma.tryGet())

      let addressStr = "a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad.onion"
      await conn.write(fmt("GET / HTTP/1.1\nHost: {addressStr}\n\n"))
      var resp: array[5, byte]
      await conn.readExactly(addr resp, 5)
      await conn.close()
      #await s.stop()
      echo string.fromBytes(resp)

    let server = TorTransport.new(torServer, {ReuseAddr}, Upgrade())
    let ma = @[MultiAddress.init("/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80").tryGet()]
    await server.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await server.accept()
      await conn.write("Hello!")
      await conn.close()

    let handlerWait = acceptHandler()

    await a()

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!
    await server.stop()

  asyncTest "test dial and start with builder":

    ##
    # Create our custom protocol
    ##
    const TestCodec = "/test/proto/1.0.0" # custom protocol string identifier

    type
      TestProto = ref object of LPProtocol # declare a custom protocol

    proc new(T: typedesc[TestProto]): T =

      # every incoming connections will be in handled in this closure
      proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
        echo "Got from remote - ", string.fromBytes(await conn.readLp(1024))
        await conn.writeLp("Roger p2p!")

        # We must close the connections ourselves when we're done with it
        await conn.close()

      return T(codecs: @[TestCodec], handler: handle)


    let rng = newRng()

    let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/8080/onion3/a2mncbqsbullu7thgm4e6zxda2xccmcgzmaq44oayhdtm6rav5vovcad:80").tryGet()

    let serverSwitch = SwitchBuilder.new()
      .withRng(rng)
      .withTorTransport(torServer, {ReuseAddr})
      .withAddress(ma)
      .withMplex()
      .withNoise()
      .build()

    # setup the custom proto
    let testProto = TestProto.new()

    serverSwitch.mount(testProto)
    await serverSwitch.start()

    let serverPeerId = serverSwitch.peerInfo.peerId
    let serverAddress = serverSwitch.peerInfo.addrs

    proc a(): Future[Switch] {.async, raises:[].} =
      let clientSwitch = SwitchBuilder.new()
        .withRng(rng)
        .withTorTransport(torServer)
        .withMplex()
        .withNoise()
        .build()

      let conn = await clientSwitch.dial(serverPeerId, serverAddress, TestCodec)

      await conn.writeLp("Hello p2p!")

      echo "Remote responded with - ", string.fromBytes(await conn.readLp(1024))
      await conn.close()
      return clientSwitch

    let client = await a()

    await allFutures(serverSwitch.stop(), client.stop())


