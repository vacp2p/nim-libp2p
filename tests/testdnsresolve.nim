{.used.}

import sequtils
import chronos, stew/byteutils
import ../libp2p/[stream/connection,
                  transports/transport,
                  transports/tcptransport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  wire]

import ./helpers

suite "DNS resolve":
  teardown:
    checkTrackers()

  proc testDns(dns: string, domain: Domain = Domain.AF_UNSPEC) {.async.} =
    let baseMa = Multiaddress.init("/" & dns & "/localhost").tryGet()

    let ma: MultiAddress = baseMa & Multiaddress.init("/tcp/0").tryGet()
    let transport: TcpTransport = TcpTransport.init(upgrade = Upgrade())
    asyncCheck transport.start(ma)

    if domain != Domain.AF_UNSPEC:
      check domain == transport.server.local.getDomain()

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await transport.accept()
      await conn.write("Hello dns!")
      await conn.close()

    let handlerWait = acceptHandler()

    #Force dns
    let streamTransport = await connect(baseMa & transport.ma[1].tryGet())

    let msg = await streamTransport.read(10)

    await handlerWait.wait(5000.millis) # when no issues will not wait that long!
    await streamTransport.closeWait()
    await transport.stop()
    check string.fromBytes(msg) == "Hello dns!"

  asyncTest "test dns resolve":
    waitFor testDns("dns")

  asyncTest "test dns4 resolve":
    waitFor testDns("dns4", Domain.AF_INET)

  asyncTest "test dns6 resolve":
    waitFor testDns("dns6", Domain.AF_INET6)

  asyncTest "test dnsaddr resolve":
    waitFor testDns("dnsaddr")

  asyncTest "test manual dns resolve":
    var dns = await resolveMAddresses(@[Multiaddress.init("/dns/localhost/tcp/0").tryGet()])
    assert dns.len >= 2
    assert Multiaddress.init("/ip4/127.0.0.1/tcp/0").get() in dns
    assert Multiaddress.init("/ip6/::1/tcp/0").get() in dns

    dns = await resolveMAddresses(@[Multiaddress.init("/dns4/localhost/tcp/0").tryGet()])
    assert dns.len >= 1
    assert Multiaddress.init("/ip4/127.0.0.1/tcp/0").get() in dns
    assert Multiaddress.init("/ip6/::1/tcp/0").get() notin dns

    dns = await resolveMAddresses(@[Multiaddress.init("/dns6/localhost/tcp/0").tryGet()])
    assert dns.len >= 1
    assert Multiaddress.init("/ip4/127.0.0.1/tcp/0").get() notin dns
    assert Multiaddress.init("/ip6/::1/tcp/0").get() in dns
