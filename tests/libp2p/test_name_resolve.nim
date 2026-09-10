# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/[sequtils, tables]
import chronos
import
  ../../libp2p/[
    stream/connection,
    transports/tcptransport,
    upgrademngrs/upgrade,
    multiaddress,
    nameresolving/nameresolver,
    nameresolving/dnsresolver,
    nameresolving/mockresolver,
    nameresolving/systemresolver,
  ]
import ../tools/[unittest, multiaddress]

suite "System nameserver discovery":
  test "nameserver entries are parsed in order":
    check parseNameServers("""
# a comment
search example.com
nameserver 10.0.0.2
nameserver 10.0.0.3
options ndots:5
""") == @[initTAddress("10.0.0.2:53"), initTAddress("10.0.0.3:53")]

  test "IPv6 nameservers are bracketed":
    check parseNameServers("nameserver fd00::2\n") == @[initTAddress("[fd00::2]:53")]

  test "IPv6 zone indices are stripped":
    check parseNameServers("nameserver fe80::1%eth0\n") ==
      @[initTAddress("[fe80::1]:53")]

  test "at most 3 nameservers are used (resolv.conf(5))":
    check parseNameServers("""
nameserver 10.0.0.1
nameserver 10.0.0.2
nameserver 10.0.0.3
nameserver 10.0.0.4
""") == @[initTAddress("10.0.0.1:53"), initTAddress("10.0.0.2:53"), initTAddress("10.0.0.3:53")]

  test "unparseable nameserver entries are skipped":
    check parseNameServers("""
nameserver not-an-address
nameserver 10.0.0.2
""") == @[initTAddress("10.0.0.2:53")]

  test "missing or empty resolv.conf content yields no servers":
    check:
      parseNameServers("").len == 0
      parseNameServers("search example.com\noptions ndots:5\n").len == 0

  test "system name servers are never empty":
    # Either parsed from /etc/resolv.conf or the default public resolvers
    check getSystemNameServers().len > 0

suite "System Resolving":
  teardown:
    checkTrackers()

  asyncTest "resolves localhost via the OS resolver":
    # localhost is in /etc/hosts (or equivalent) everywhere, so this works
    # without network access - and is something DnsResolver cannot do.
    let resolver = SystemResolver.new()
    let addrs = await resolver.resolveIp("localhost", 4001.Port)
    check:
      addrs.len > 0
      initTAddress("127.0.0.1:4001") in addrs
    await resolver.close()

  asyncTest "AF_INET filter returns only IPv4 addresses":
    let resolver = SystemResolver.new()
    let addrs = await resolver.resolveIp("localhost", 0.Port, Domain.AF_INET)
    check:
      addrs.len > 0
      addrs.allIt(it.family == AddressFamily.IPv4)
    await resolver.close()

  asyncTest "unresolvable name yields an empty result":
    let resolver = SystemResolver.new()
    check (await resolver.resolveIp("thisdomain.doesnot.exist", 0.Port)).len == 0
    await resolver.close()

  asyncTest "TXT queries are delegated to the fallback resolver":
    let fallback = MockResolver.new()
    fallback.txtResponses["_dnsaddr.test.io"] = @["dnsaddr=/ip4/127.0.0.1/tcp/4001"]
    let resolver = SystemResolver.new(txtResolver = fallback)
    check await(resolver.resolveTxt("_dnsaddr.test.io")) ==
      @["dnsaddr=/ip4/127.0.0.1/tcp/4001"]
    await resolver.close()

  asyncTest "concurrent resolutions all complete":
    let resolver = SystemResolver.new()
    # all submitted before awaiting any, so they resolve concurrently
    let futs = (0 ..< 8).mapIt(resolver.resolveIp("localhost", Port(4001 + it)))
    for fut in futs:
      check (await fut).len > 0
    await resolver.close()

  asyncTest "close without any resolution":
    let resolver = SystemResolver.new()
    await resolver.close()
    check (await resolver.resolveIp("localhost", 4001.Port)).len == 0
    await resolver.close() # idempotent

  asyncTest "cancelled queued resolutions do not poison the worker pool":
    let resolver = SystemResolver.new(workers = 1)
    let resolutions =
      (0 ..< 16).mapIt(resolver.resolveIp("cancel-" & $it & ".invalid", 0.Port))
    for i in 1 ..< resolutions.len:
      await resolutions[i].cancelAndWait()
    discard await resolutions[0]

    check (await resolver.resolveIp("localhost", 4001.Port)).len > 0
    await resolver.close()

suite "Name resolving":
  suite "Generic Resolving":
    var resolver {.threadvar.}: MockResolver

    proc testOne(input: string, output: seq[MultiAddress]) {.async.} =
      let resolved = await resolver.resolveMAddress(ma(input))
      check resolved == output

    proc testOne(input: string, output: seq[string]) {.async.} =
      await testOne(input, output.mapIt(ma(it)))

    proc testOne(input, output: string) {.async.} =
      await testOne(input, @[ma(output)])

    asyncSetup:
      resolver = MockResolver.new()

    asyncTest "test multi address dns resolve":
      resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
      resolver.ipResponses[("localhost", true)] = @["::1"]

      await testOne("/dns/localhost/udp/0", @["/ip4/127.0.0.1/udp/0", "/ip6/::1/udp/0"])
      await testOne("/dns4/localhost/tcp/0", "/ip4/127.0.0.1/tcp/0")
      await testOne("/dns6/localhost/tcp/0", "/ip6/::1/tcp/0")
      await testOne(
        "/dns6/localhost/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        "/ip6/::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
      )

      await testOne(
        "/dns4/localhost/tcp/443/tls/sni/example.com/ws",
        "/ip4/127.0.0.1/tcp/443/tls/sni/example.com/ws",
      )

    asyncTest "DNS replacement preserves prefixes, suffixes and chained components":
      resolver.ipResponses[("v4.test", false)] = @["192.0.2.1"]
      resolver.ipResponses[("v6.test", true)] = @["2001:db8::1"]

      await testOne("/dns4/v4.test", "/ip4/192.0.2.1")
      await testOne(
        "/p2p-circuit/dns4/v4.test/tcp/4001",
        "/p2p-circuit/ip4/192.0.2.1/tcp/4001",
      )
      await testOne(
        "/dns4/v4.test/dns6/v6.test/tcp/4001",
        "/ip4/192.0.2.1/ip6/2001:db8::1/tcp/4001",
      )

    asyncTest "DNS replacement stops at the lookup limit":
      var input = ""
      for i in 0 .. MaxDnsLookups:
        let hostname = "lookup-" & $i & ".test"
        input.add("/dns4/" & hostname)
        resolver.ipResponses[(hostname, false)] = @["192.0.2.1"]
      input.add("/tcp/4001")

      await testOne(input, newSeq[string]())

    asyncTest "test non dns resolve":
      resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
      resolver.ipResponses[("localhost", true)] = @["::1"]

      await testOne("/ip6/::1/tcp/0", "/ip6/::1/tcp/0")

    asyncTest "dnsaddr recursive test":
      resolver.txtResponses["_dnsaddr.bootstrap.libp2p.io"] = @[
        "dnsaddr=/dnsaddr/sjc-1.bootstrap.libp2p.io/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        "dnsaddr=/dnsaddr/ams-2.bootstrap.libp2p.io/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
      ]

      resolver.txtResponses["_dnsaddr.sjc-1.bootstrap.libp2p.io"] = @[
        "dnsaddr=/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        "dnsaddr=/ip4/147.75.69.143/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
      ]

      resolver.txtResponses["_dnsaddr.ams-2.bootstrap.libp2p.io"] = @[
        "dnsaddr=/ip4/147.75.83.83/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
        "dnsaddr=/ip6/2604:1380:2000:7a00::1/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
      ]

      await testOne(
        "/dnsaddr/bootstrap.libp2p.io/",
        @[
          "/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "/ip4/147.75.69.143/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "/ip4/147.75.83.83/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
          "/ip6/2604:1380:2000:7a00::1/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
        ],
      )

    asyncTest "dnsaddr suffix matching test":
      resolver.txtResponses["_dnsaddr.bootstrap.libp2p.io"] = @[
        "dnsaddr=/dnsaddr/ams-2.bootstrap.libp2p.io/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
        "dnsaddr=/dnsaddr/sjc-1.bootstrap.libp2p.io/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        "dnsaddr=/dnsaddr/nrt-1.bootstrap.libp2p.io/tcp/4001/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
        "dnsaddr=/dnsaddr/ewr-1.bootstrap.libp2p.io/tcp/4001/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
      ]

      resolver.txtResponses["_dnsaddr.sjc-1.bootstrap.libp2p.io"] = @[
        "dnsaddr=/ip4/147.75.69.143/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        "dnsaddr=/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
      ]

      resolver.txtResponses["_dnsaddr.ams-1.bootstrap.libp2p.io"] = @[
        "dnsaddr=/ip4/147.75.69.143/tcp/4001/p2p/shouldbefiltered",
        "dnsaddr=/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/shouldbefiltered",
      ]

      await testOne(
        "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        @[
          "/ip4/147.75.69.143/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        ],
      )

    asyncTest "dnsaddr matches the complete suffix and skips malformed records":
      const
        peerId = "QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
        otherPeerId = "QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb"
      resolver.txtResponses["_dnsaddr.peers.test"] = @[
        "not-a-dnsaddr-record",
        "dnsaddr=not-a-multiaddress",
        "dnsaddr=/ip4/192.0.2.2/tcp/4002/p2p/" & peerId,
        "dnsaddr=/ip4/192.0.2.3/tcp/4001/p2p/" & otherPeerId,
        "dnsaddr=/ip4/192.0.2.1/tcp/4001/p2p/" & peerId,
      ]

      await testOne(
        "/p2p-circuit/dnsaddr/peers.test/tcp/4001/p2p/" & peerId,
        "/p2p-circuit/ip4/192.0.2.1/tcp/4001/p2p/" & peerId,
      )

    asyncTest "dnsaddr record limit counts only applicable records":
      const peerId = "QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
      var
        records: seq[string]
        expected: seq[string]

      for i in 1 .. MaxDnsaddrRecords:
        records.add("unrelated-txt-record-" & $i)
        records.add("dnsaddr=not-a-multiaddress")
        records.add(
          "dnsaddr=/ip4/198.51.100." & $i & "/tcp/4002/p2p/" & peerId
        )

      for i in 1 .. (MaxDnsaddrRecords + 4):
        let address = "/ip4/192.0.2." & $i & "/tcp/4001/p2p/" & peerId
        records.add("dnsaddr=" & address)
        if i <= MaxDnsaddrRecords:
          expected.add(address)

      resolver.txtResponses["_dnsaddr.applicable-limit.test"] = records

      await testOne(
        "/dnsaddr/applicable-limit.test/tcp/4001/p2p/" & peerId, expected
      )

    asyncTest "dnsaddr bounds records and removes duplicate outputs":
      var records: seq[string]
      var expected: seq[string]
      for i in 1 .. 20:
        let address = "/ip4/192.0.2." & $i & "/tcp/4001"
        records.add("dnsaddr=" & address)
        # One duplicate is inserted at the front below, so the first bounded
        # window contains unique addresses 1 through MaxDnsaddrRecords - 1.
        if i < MaxDnsaddrRecords:
          expected.add(address)
      records.insert(records[0])
      resolver.txtResponses["_dnsaddr.limit.test"] = records

      await testOne("/dnsaddr/limit.test", expected)

    asyncTest "dnsaddr bounds total output":
      var
        rootRecords: seq[string]
        expected: seq[string]
      for branch in 1 .. MaxDnsaddrRecords:
        let branchName = "branch-" & $branch & ".test"
        rootRecords.add("dnsaddr=/dnsaddr/" & branchName)

        var branchRecords: seq[string]
        for host in 1 .. MaxDnsaddrRecords:
          let address =
            "/ip4/198.51." & $branch & "." & $host & "/tcp/4001"
          branchRecords.add("dnsaddr=" & address)
          if expected.len < MaxResolvedAddresses:
            expected.add(address)
        resolver.txtResponses["_dnsaddr." & branchName] = branchRecords
      resolver.txtResponses["_dnsaddr.output-limit.test"] = rootRecords

      await testOne("/dnsaddr/output-limit.test", expected)

    asyncTest "dnsaddr stops at the recursion limit":
      for i in 0 .. MaxDnsaddrRecursion:
        resolver.txtResponses["_dnsaddr.level-" & $i & ".test"] =
          @["dnsaddr=/dnsaddr/level-" & $(i + 1) & ".test"]
      resolver.txtResponses[
        "_dnsaddr.level-" & $(MaxDnsaddrRecursion + 1) & ".test"
      ] = @["dnsaddr=/ip4/192.0.2.1/tcp/4001"]

      await testOne("/dnsaddr/level-0.test", newSeq[string]())

    asyncTest "dnsaddr infinite recursion":
      resolver.txtResponses["_dnsaddr.bootstrap.libp2p.io"] =
        @["dnsaddr=/dnsaddr/bootstrap.libp2p.io"]

      await testOne("/dnsaddr/bootstrap.libp2p.io/", newSeq[string]())

    test "getHostname":
      check:
        ma("/dnsaddr/bootstrap.libp2p.io/").getHostname == "bootstrap.libp2p.io"

        MultiAddress
          .init(
            "/ip4/147.75.69.143/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
          )
          .tryGet().getHostname == "147.75.69.143"

        MultiAddress
          .init(
            "/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
          )
          .tryGet().getHostname == "2604:1380:1000:6000::1"
        ma("/dns/localhost/udp/0").getHostname == "localhost"
        ma("/dns4/hello.com/udp/0").getHostname == "hello.com"
        ma("/dns6/hello.com/udp/0").getHostname == "hello.com"
        ma("/p2p-circuit/dns4/hello.com/tcp/4001").getHostname == "hello.com"
        ma(
          "/ip4/192.0.2.1/tcp/4001/p2p/" &
            "QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN" &
            "/p2p-circuit/dns4/hello.com/tcp/4001"
        ).getHostname == "hello.com"
        ma("/wss/").getHostname == ""

  suite "DNS Resolving":
    teardown:
      checkTrackers()

    asyncTest "test manual dns ip resolve":
      ## DNS mock server
      proc clientMark1(
          transp: DatagramTransport, raddr: TransportAddress
      ): Future[void] {.async: (raises: []).} =
        try:
          let msg = transp.getMessage()
          var resp =
            if msg[24] == 1: #AAAA or A
              "\xae\xbf\x81\x80\x00\x01\x00\x03\x00\x00\x00\x00\x06\x73\x74\x61" &
                "\x74\x75\x73\x02\x69\x6d\x00\x00\x01\x00\x01\xc0\x0c\x00\x01\x00" &
                "\x01\x00\x00\x00\x4f\x00\x04\x68\x16\x18\xb5\xc0\x0c\x00\x01\x00" &
                "\x01\x00\x00\x00\x4f\x00\x04\xac\x43\x0a\xa1\xc0\x0c\x00\x01\x00" &
                "\x01\x00\x00\x00\x4f\x00\x04\x68\x16\x19\xb5"
            else:
              "\xe8\xc5\x81\x80\x00\x01\x00\x03\x00\x00\x00\x00\x06\x73\x74\x61" &
                "\x74\x75\x73\x02\x69\x6d\x00\x00\x1c\x00\x01\xc0\x0c\x00\x1c\x00" &
                "\x01\x00\x00\x00\x4f\x00\x10\x26\x06\x47\x00\x00\x10\x00\x00\x00" &
                "\x00\x00\x00\x68\x16\x19\xb5\xc0\x0c\x00\x1c\x00\x01\x00\x00\x00" &
                "\x4f\x00\x10\x26\x06\x47\x00\x00\x10\x00\x00\x00\x00\x00\x00\x68" &
                "\x16\x18\xb5\xc0\x0c\x00\x1c\x00\x01\x00\x00\x00\x4f\x00\x10\x26" &
                "\x06\x47\x00\x00\x10\x00\x00\x00\x00\x00\x00\xac\x43\x0a\xa1"
          # Echo back the query id so the resolver accepts the response.
          resp[0] = char(msg[0])
          resp[1] = char(msg[1])
          await transp.sendTo(raddr, resp)
        except CancelledError, transport.TransportError:
          raiseAssert "unexpected error: " & getCurrentExceptionMsg()

      let server = newDatagramTransport(clientMark1)

      # The test
      let dnsresolver = DnsResolver.new(@[server.localAddress])

      check await(dnsresolver.resolveIp("status.im", 0.Port, Domain.AF_UNSPEC)) ==
        mapIt(
          @[
            "104.22.24.181:0", "172.67.10.161:0", "104.22.25.181:0",
            "[2606:4700:10::6816:19b5]:0", "[2606:4700:10::6816:18b5]:0",
            "[2606:4700:10::ac43:aa1]:0",
          ],
          initTAddress(it),
        )
      check await(dnsresolver.resolveIp("status.im", 0.Port, Domain.AF_INET)) ==
        mapIt(
          @["104.22.24.181:0", "172.67.10.161:0", "104.22.25.181:0"], initTAddress(it)
        )
      check await(dnsresolver.resolveIp("status.im", 0.Port, Domain.AF_INET6)) ==
        mapIt(
          @[
            "[2606:4700:10::6816:19b5]:0", "[2606:4700:10::6816:18b5]:0",
            "[2606:4700:10::ac43:aa1]:0",
          ],
          initTAddress(it),
        )

      await server.closeWait()

    asyncTest "test unresponsive dns server":
      var unresponsiveTentatives = 0
      ## DNS mock server
      proc clientMark1(
          transp: DatagramTransport, raddr: TransportAddress
      ): Future[void] {.async: (raises: []).} =
        unresponsiveTentatives.inc()

      proc clientMark2(
          transp: DatagramTransport, raddr: TransportAddress
      ): Future[void] {.async: (raises: []).} =
        try:
          let msg = transp.getMessage()
          var resp =
            "\xae\xbf\x81\x80\x00\x01\x00\x03\x00\x00\x00\x00\x06\x73\x74\x61" &
            "\x74\x75\x73\x02\x69\x6d\x00\x00\x01\x00\x01\xc0\x0c\x00\x01\x00" &
            "\x01\x00\x00\x00\x4f\x00\x04\x68\x16\x18\xb5\xc0\x0c\x00\x01\x00" &
            "\x01\x00\x00\x00\x4f\x00\x04\xac\x43\x0a\xa1\xc0\x0c\x00\x01\x00" &
            "\x01\x00\x00\x00\x4f\x00\x04\x68\x16\x19\xb5"
          # Echo back the query id so the resolver accepts the response.
          resp[0] = char(msg[0])
          resp[1] = char(msg[1])
          await transp.sendTo(raddr, resp)
        except CancelledError, transport.TransportError:
          raiseAssert "unexpected error: " & getCurrentExceptionMsg()

      let
        unresponsiveServer = newDatagramTransport(clientMark1)
        server = newDatagramTransport(clientMark2)

      # The test
      let dnsresolver =
        DnsResolver.new(@[unresponsiveServer.localAddress, server.localAddress])

      check unresponsiveTentatives == 0 # client callback not yet called

      check await(dnsresolver.resolveIp("status.im", 0.Port, Domain.AF_INET)) ==
        mapIt(
          @["104.22.24.181:0", "172.67.10.161:0", "104.22.25.181:0"], initTAddress(it)
        )

      check unresponsiveTentatives == 1 # client callback called

      check await(dnsresolver.resolveIp("status.im", 0.Port, Domain.AF_INET)) ==
        mapIt(
          @["104.22.24.181:0", "172.67.10.161:0", "104.22.25.181:0"], initTAddress(it)
        )

      check unresponsiveTentatives == 1 # client callback should not be called anymore

      await server.closeWait()
      await unresponsiveServer.closeWait()

    asyncTest "inexisting domain resolving":
      let dnsresolver = DnsResolver.new(getSystemNameServers())
      let invalid = await dnsresolver.resolveIp("thisdomain.doesnot.exist", 0.Port)
      check invalid.len == 0

    asyncTest "wrong domain resolving":
      let dnsresolver = DnsResolver.new(getSystemNameServers())
      let invalid = await dnsresolver.resolveIp("", 0.Port)
      check invalid.len == 0

    # asyncTest "unreachable dns server":
    #   var dnsresolver = DnsResolver.new(@[initTAddress("172.67.10.161:0")])
    #   let invalid = await dnsresolver.resolveIp("google.fr", 0.Port)
    #   check invalid.len == 0

  suite "DNS cancellation":
    teardown:
      checkTrackers()

    asyncTest "cancelling a dual-stack lookup closes both query sockets":
      let received = newAsyncEvent()
      var queries = 0
      proc discardQuery(
          transp: DatagramTransport, raddr: TransportAddress
      ) {.async: (raises: []).} =
        inc queries
        if queries == 2:
          received.fire()

      let server = newDatagramTransport(discardQuery)
      let resolver = DnsResolver.new(@[server.localAddress])
      let lookup = resolver.resolveIp("example.com", Port(0))
      await received.wait().wait(1.seconds)
      await lookup.cancelAndWait()
      await server.closeWait()
