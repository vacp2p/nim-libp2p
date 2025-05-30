{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[sequtils, tables]
import chronos
import
  ../libp2p/[
    stream/connection,
    transports/tcptransport,
    upgrademngrs/upgrade,
    multiaddress,
    nameresolving/nameresolver,
    nameresolving/dnsresolver,
    nameresolving/mockresolver,
  ]

import ./helpers
#
#Cloudflare
const fallbackDnsServers =
  @[
    initTAddress("1.1.1.1:53"),
    initTAddress("1.0.0.1:53"),
    initTAddress("[2606:4700:4700::1111]:53"),
  ]

const unixPlatform =
  defined(linux) or defined(solaris) or defined(macosx) or defined(freebsd) or
  defined(netbsd) or defined(openbsd) or defined(dragonfly)

when unixPlatform:
  import std/strutils

proc guessOsNameServers(): seq[TransportAddress] =
  when unixPlatform:
    var resultSeq = newSeqOfCap[TransportAddress](3)
    try:
      for l in lines("/etc/resolv.conf"):
        let lineParsed = l.strip().split(seps = Whitespace + {'%'}, maxsplit = 2)
        if lineParsed.len < 2:
          continue
        if lineParsed[0].startsWith('#'):
          continue

        if lineParsed[0] == "nameserver":
          resultSeq.add(initTAddress(lineParsed[1], Port(53)))

          if resultSeq.len > 2:
            break
            #3 nameserver max on linux
    except CatchableError as err:
      echo "Failed to get unix nameservers ", err.msg
    finally:
      if resultSeq.len > 0:
        return resultSeq
      return fallbackDnsServers
  elif defined(windows):
    #TODO
    return fallbackDnsServers
  else:
    return fallbackDnsServers

suite "Name resolving":
  suite "Generic Resolving":
    var resolver {.threadvar.}: MockResolver

    proc testOne(input: string, output: seq[MultiAddress]): bool =
      let resolved = waitFor resolver.resolveMAddress(MultiAddress.init(input).tryGet())
      if resolved != output:
        echo "Expected ", output
        echo "Got ", resolved
        return false
      return true

    proc testOne(input: string, output: seq[string]): bool =
      testOne(input, output.mapIt(MultiAddress.init(it).tryGet()))

    proc testOne(input, output: string): bool =
      testOne(input, @[MultiAddress.init(output).tryGet()])

    asyncSetup:
      resolver = MockResolver.new()

    asyncTest "test multi address dns resolve":
      resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
      resolver.ipResponses[("localhost", true)] = @["::1"]

      check testOne("/dns/localhost/udp/0", @["/ip4/127.0.0.1/udp/0", "/ip6/::1/udp/0"])
      check testOne("/dns4/localhost/tcp/0", "/ip4/127.0.0.1/tcp/0")
      check testOne("/dns6/localhost/tcp/0", "/ip6/::1/tcp/0")
      check testOne(
        "/dns6/localhost/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        "/ip6/::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
      )

    asyncTest "test non dns resolve":
      resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
      resolver.ipResponses[("localhost", true)] = @["::1"]

      check testOne("/ip6/::1/tcp/0", "/ip6/::1/tcp/0")

    asyncTest "dnsaddr recursive test":
      resolver.txtResponses["_dnsaddr.bootstrap.libp2p.io"] =
        @[
          "dnsaddr=/dnsaddr/sjc-1.bootstrap.libp2p.io/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "dnsaddr=/dnsaddr/ams-2.bootstrap.libp2p.io/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
        ]

      resolver.txtResponses["_dnsaddr.sjc-1.bootstrap.libp2p.io"] =
        @[
          "dnsaddr=/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "dnsaddr=/ip4/147.75.69.143/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        ]

      resolver.txtResponses["_dnsaddr.ams-2.bootstrap.libp2p.io"] =
        @[
          "dnsaddr=/ip4/147.75.83.83/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
          "dnsaddr=/ip6/2604:1380:2000:7a00::1/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
        ]

      check testOne(
        "/dnsaddr/bootstrap.libp2p.io/",
        @[
          "/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "/ip4/147.75.69.143/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "/ip4/147.75.83.83/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
          "/ip6/2604:1380:2000:7a00::1/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
        ],
      )

    asyncTest "dnsaddr suffix matching test":
      resolver.txtResponses["_dnsaddr.bootstrap.libp2p.io"] =
        @[
          "dnsaddr=/dnsaddr/ams-2.bootstrap.libp2p.io/tcp/4001/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
          "dnsaddr=/dnsaddr/sjc-1.bootstrap.libp2p.io/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "dnsaddr=/dnsaddr/nrt-1.bootstrap.libp2p.io/tcp/4001/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
          "dnsaddr=/dnsaddr/ewr-1.bootstrap.libp2p.io/tcp/4001/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
        ]

      resolver.txtResponses["_dnsaddr.sjc-1.bootstrap.libp2p.io"] =
        @[
          "dnsaddr=/ip4/147.75.69.143/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "dnsaddr=/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        ]

      resolver.txtResponses["_dnsaddr.ams-1.bootstrap.libp2p.io"] =
        @[
          "dnsaddr=/ip4/147.75.69.143/tcp/4001/p2p/shouldbefiltered",
          "dnsaddr=/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/shouldbefiltered",
        ]

      check testOne(
        "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        @[
          "/ip4/147.75.69.143/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
          "/ip6/2604:1380:1000:6000::1/tcp/4001/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
        ],
      )

    asyncTest "dnsaddr infinite recursion":
      resolver.txtResponses["_dnsaddr.bootstrap.libp2p.io"] =
        @["dnsaddr=/dnsaddr/bootstrap.libp2p.io"]

      check testOne("/dnsaddr/bootstrap.libp2p.io/", newSeq[string]())

    test "getHostname":
      check:
        MultiAddress.init("/dnsaddr/bootstrap.libp2p.io/").tryGet().getHostname ==
          "bootstrap.libp2p.io"

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
        MultiAddress.init("/dns/localhost/udp/0").tryGet().getHostname == "localhost"
        MultiAddress.init("/dns4/hello.com/udp/0").tryGet().getHostname == "hello.com"
        MultiAddress.init("/dns6/hello.com/udp/0").tryGet().getHostname == "hello.com"
        MultiAddress.init("/wss/").tryGet().getHostname == ""

  suite "DNS Resolving":
    teardown:
      checkTrackers()

    asyncTest "test manual dns ip resolve":
      ## DNS mock server
      proc clientMark1(
          transp: DatagramTransport, raddr: TransportAddress
      ): Future[void] {.async.} =
        var msg = transp.getMessage()
        let resp =
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
        await transp.sendTo(raddr, resp)

      let server = newDatagramTransport(clientMark1)

      # The test
      var dnsresolver = DnsResolver.new(@[server.localAddress])

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
      ): Future[void] {.async.} =
        unresponsiveTentatives.inc()
        check unresponsiveTentatives == 1

      proc clientMark2(
          transp: DatagramTransport, raddr: TransportAddress
      ): Future[void] {.async.} =
        var msg = transp.getMessage()
        let resp =
          "\xae\xbf\x81\x80\x00\x01\x00\x03\x00\x00\x00\x00\x06\x73\x74\x61" &
          "\x74\x75\x73\x02\x69\x6d\x00\x00\x01\x00\x01\xc0\x0c\x00\x01\x00" &
          "\x01\x00\x00\x00\x4f\x00\x04\x68\x16\x18\xb5\xc0\x0c\x00\x01\x00" &
          "\x01\x00\x00\x00\x4f\x00\x04\xac\x43\x0a\xa1\xc0\x0c\x00\x01\x00" &
          "\x01\x00\x00\x00\x4f\x00\x04\x68\x16\x19\xb5"
        await transp.sendTo(raddr, resp)

      let
        unresponsiveServer = newDatagramTransport(clientMark1)
        server = newDatagramTransport(clientMark2)

      # The test
      var dnsresolver =
        DnsResolver.new(@[unresponsiveServer.localAddress, server.localAddress])

      check await(dnsresolver.resolveIp("status.im", 0.Port, Domain.AF_INET)) ==
        mapIt(
          @["104.22.24.181:0", "172.67.10.161:0", "104.22.25.181:0"], initTAddress(it)
        )

      check await(dnsresolver.resolveIp("status.im", 0.Port, Domain.AF_INET)) ==
        mapIt(
          @["104.22.24.181:0", "172.67.10.161:0", "104.22.25.181:0"], initTAddress(it)
        )

      await server.closeWait()
      await unresponsiveServer.closeWait()

    asyncTest "inexisting domain resolving":
      var dnsresolver = DnsResolver.new(guessOsNameServers())
      let invalid = await dnsresolver.resolveIp("thisdomain.doesnot.exist", 0.Port)
      check invalid.len == 0

    asyncTest "wrong domain resolving":
      var dnsresolver = DnsResolver.new(guessOsNameServers())
      let invalid = await dnsresolver.resolveIp("", 0.Port)
      check invalid.len == 0

    asyncTest "unreachable dns server":
      var dnsresolver = DnsResolver.new(@[initTAddress("172.67.10.161:53")])
      let invalid = await dnsresolver.resolveIp("google.fr", 0.Port)
      check invalid.len == 0
