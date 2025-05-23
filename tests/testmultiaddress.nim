{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/sequtils

import unittest2
import stew/byteutils
import ../libp2p/[multicodec, multiaddress, protobuf/minprotobuf]

type PatternVector = object
  pattern: MaPattern
  good: seq[string]
  bad: seq[string]

const
  SuccessVectors = [
    "/ip4/1.2.3.4", "/ip4/0.0.0.0", "/ip6/::1",
    "/ip6/2601:9:4f81:9700:803e:ca65:66e8:c21",
    "/ip6/2601:9:4f81:9700:803e:ca65:66e8:c21/udp/1234/quic",
    "/ip6/2601:9:4f81:9700:803e:ca65:66e8:c21/udp/1234/quic-v1",
    "/ip6zone/x/ip6/fe80::1", "/ip6zone/x%y/ip6/fe80::1", "/ip6zone/x%y/ip6/::",
    "/ip6zone/x/ip6/fe80::1/udp/1234/quic", "/ip6zone/x/ip6/fe80::1/udp/1234/quic-v1",
    "/onion/timaq4ygg2iegci7:1234", "/onion/timaq4ygg2iegci7:80/http",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:1234",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:80/http",
    "/udp/0", "/tcp/0", "/sctp/0", "/udp/1234", "/tcp/1234", "/sctp/1234", "/udp/65535",
    "/tcp/65535", "/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC", "/udp/1234/sctp/1234",
    "/udp/1234/udt", "/udp/1234/utp", "/tcp/1234/http", "/tcp/1234/https",
    "/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip4/127.0.0.1/udp/1234", "/ip4/127.0.0.1/udp/0", "/ip4/127.0.0.1/tcp/1234",
    "/ip4/127.0.0.1/tcp/1234/", "/ip4/127.0.0.1/udp/1234/quic",
    "/ip4/192.168.80.3/udp/33422/quic-v1",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip4/127.0.0.1/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip4/127.0.0.1/tcp/8000/wss/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/tcp/8000/tls/ws/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/unix/a/b/c/d/e", "/unix/stdio", "/ip4/1.2.3.4/tcp/80/unix/a/b/c/d/e/f",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234/unix/stdio",
    "/ip4/127.0.0.1/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234/unix/stdio",
    "/dns/example.io/udp/65535", "/dns4/example.io/udp/65535",
    "/dns6/example.io/udp/65535", "/dnsaddr/example.io/udp/65535",
  ]

  FailureVectors = [
    "", "/", "/ip4", "/ip4/::1", "/ip4/fdpsofodsajfdoisa", "/ip6", "/ip6zone",
    "/ip6zone/", "/ip6zone//ip6/fe80::1", "/udp", "/tcp", "/sctp", "/udp/65536",
    "/tcp/65536", "/quic/65536", "/quic-v1/65536", "/onion/9imaq4ygg2iegci7:80",
    "/onion/aaimaq4ygg2iegci7:80", "/onion/timaq4ygg2iegci7:0",
    "/onion/timaq4ygg2iegci7:-1", "/onion/timaq4ygg2iegci7",
    "/onion/timaq4ygg2iegci@:666",
    "/onion3/9ww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:80",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd7:80",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:0",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:-1",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyy@:666",
    "/udp/1234/sctp", "/udp/1234/udt/1234", "/udp/1234/utp/1234",
    "/ip4/127.0.0.1/udp/jfodsajfidosajfoidsa", "/ip4/127.0.0.1/udp",
    "/ip4/127.0.0.1/tcp/jfodsajfidosajfoidsa", "/ip4/127.0.0.1/tcp",
    "/ip4/127.0.0.1/quic/1234", "/ip4/127.0.0.1/quic-v1/1234", "/ip4/127.0.0.1/ipfs",
    "/ip4/127.0.0.1/ipfs/tcp", "/ip4/127.0.0.1/p2p", "/ip4/127.0.0.1/p2p/tcp", "/unix",
  ]

  RustSuccessVectors = [
    "/ip4/1.2.3.4", "/ip4/0.0.0.0", "/ip6/::1",
    "/ip6/2601:9:4f81:9700:803e:ca65:66e8:c21", "/udp/0", "/tcp/0", "/sctp/0",
    "/udp/1234", "/tcp/1234", "/sctp/1234", "/udp/65535", "/tcp/65535",
    "/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC", "/udp/1234/sctp/1234",
    "/udp/1234/udt", "/udp/1234/utp", "/tcp/1234/http", "/tcp/1234/https",
    "/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip4/127.0.0.1/udp/1234", "/ip4/127.0.0.1/udp/0", "/ip4/127.0.0.1/tcp/1234",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip6/2001:8a0:7ac5:4201:3ac9:86ff:fe31:7095/tcp/8000/ws/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/p2p-webrtc-star/ip4/127.0.0.1/tcp/9090/ws/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/tcp/9090/p2p-circuit/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
  ]

  RustSuccessExpects = [
    "0401020304", "0400000000", "2900000000000000000000000000000001",
    "29260100094F819700803ECA6566E80C21", "91020000", "060000", "84010000", "910204D2",
    "0604D2", "840104D2", "9102FFFF", "06FFFF",
    "A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B",
    "910204D2840104D2", "910204D2AD02", "910204D2AE02", "0604D2E003", "0604D2BB03",
    "A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B0604D2",
    "047F000001910204D2", "047F00000191020000", "047F0000010604D2",
    "047F000001A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B",
    "047F000001A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B0604D2",
    "29200108A07AC542013AC986FFFE317095061F40DD03A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B",
    "9302047F000001062382DD03A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B",
    "047F000001062382A202A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B",
  ]

  RustFailureVectors = [
    "/ip4", "/ip4/::1", "/ip4/fdpsofodsajfdoisa", "/ip6", "/udp", "/tcp", "/sctp",
    "/udp/65536", "/tcp/65536", "/onion/9imaq4ygg2iegci7:80",
    "/onion/aaimaq4ygg2iegci7:80", "/onion/timaq4ygg2iegci7:0",
    "/onion/timaq4ygg2iegci7:-1", "/onion/timaq4ygg2iegci7",
    "/onion/timaq4ygg2iegci@:666",
    "/onion3/9ww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:80",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd7:80",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:0",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:-1",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd",
    "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyy@:666",
    "/udp/1234/sctp", "/udp/1234/udt/1234", "/udp/1234/utp/1234",
    "/ip4/127.0.0.1/udp/jfodsajfidosajfoidsa", "/ip4/127.0.0.1/udp",
    "/ip4/127.0.0.1/tcp/jfodsajfidosajfoidsa", "/ip4/127.0.0.1/tcp",
    "/ip4/127.0.0.1/ipfs", "/ip4/127.0.0.1/ipfs/tcp", "/p2p-circuit/50",
  ]

  PathVectors = ["/unix/tmp/p2pd.sock", "/unix/a/b/c/d/e/f/g/h/i.sock"]

  PathExpects = [
    "90030E2F746D702F703270642E736F636B",
    "9003172F612F622F632F642F652F662F672F682F692E736F636B",
  ]

  PatternVectors = [
    PatternVector(
      pattern: IP,
      good: @["/ip4/0.0.0.0", "/ip6/fc00::"],
      bad: @["/ip4/0.0.0.0/tcp/555", "/udp/789/ip6/fc00::"],
    ),
    PatternVector(
      pattern: TCP,
      good: @["/ip4/0.0.7.6/tcp/1234", "/ip6/::/tcp/0"],
      bad: @["/tcp/12345", "/ip6/fc00::/udp/5523/tcp/9543"],
    ),
    PatternVector(
      pattern: UDP,
      good: @["/ip4/0.0.7.6/udp/1234", "/ip6/::/udp/0"],
      bad: @["/udp/12345", "/ip6/fc00::/tcp/5523/udp/9543"],
    ),
    PatternVector(
      pattern: UTP,
      good: @["/ip4/1.2.3.4/udp/3456/utp", "/ip6/::/udp/0/utp"],
      bad:
        @["/ip4/0.0.0.0/tcp/12345/utp", "/ip6/fc00::/ip4/0.0.0.0/udp/1234/utp", "/utp"],
    ),
    PatternVector(
      pattern: QUIC,
      good: @["/ip4/1.2.3.4/udp/1234/quic", "/ip6/::/udp/1234/quic"],
      bad:
        @[
          "/ip4/0.0.0.0/tcp/12345/quic", "/ip6/fc00::/ip4/0.0.0.0/udp/1234/quic",
          "/quic",
        ],
    ),
    PatternVector(
      pattern: QUIC_V1,
      good: @["/ip4/1.2.3.4/udp/1234/quic-v1", "/ip6/::/udp/1234/quic-v1"],
      bad:
        @[
          "/ip4/0.0.0.0/tcp/12345/quic-v1", "/ip6/fc00::/ip4/0.0.0.0/udp/1234/quic-v1",
          "/quic-v1",
        ],
    ),
    PatternVector(
      pattern: IPFS,
      good:
        @[
          "/ip4/1.2.3.4/tcp/1234/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ip6/::/tcp/1234/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ip6/::/udp/1234/utp/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ip4/0.0.0.0/udp/1234/utp/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
        ],
      bad:
        @[
          "/ip4/1.2.3.4/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ip6/::/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/tcp/123/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ip6/::/udp/1234/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ip6/::/utp/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
          "/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
        ],
    ),
    PatternVector(
      pattern: DNS,
      good:
        @[
          "/dns/example.io", "/dnsaddr/example.io", "/dns4/example.io",
          "/dns6/example.io",
        ],
      bad: @["/ip4/127.0.0.1"],
    ),
    PatternVector(
      pattern: WebRTCDirect,
      good:
        @[
          "/ip4/1.2.3.4/tcp/3456/http/p2p-webrtc-direct",
          "/ip6/::/tcp/0/http/p2p-webrtc-direct",
        ],
      bad:
        @["/ip4/0.0.0.0", "/ip6/fc00::", "/udp/12345", "/ip6/fc00::/tcp/5523/udp/9543"],
    ),
    PatternVector(
      pattern: HTTP,
      good:
        @[
          "/ip4/1.2.3.4/http", "/dns4/example.io/http", "/dns6/::/tcp/7011/http",
          "/dnsaddr/example.io/http", "/ip6/fc00::/http",
        ],
      bad:
        @["/ip4/1.2.3.4/https", "/ip4/0.0.0.0/tcp/12345/quic", "/ip6/fc00::/tcp/5523"],
    ),
    PatternVector(
      pattern: HTTPS,
      good:
        @[
          "/ip4/1.2.3.4/https", "/dns4/example.io/https", "/dns6/::/tcp/7011/https",
          "/ip6/fc00::/https",
        ],
      bad: @["/ip4/1.2.3.4/http", "/ip4/0.0.0.0/tcp/12345/quic", "/ip6/fc00::/tcp/5523"],
    ),
  ]

  ZeroPathFailureVectors = [
    "900300", # /unix//
    "2A00", # /ip6zone//
    "3800", # /dnsaddr//
    "3600", # /dns4//
    "3700", # /dns6//
  ]

  CrashesVectors = [
    "0401020304060050900366",
    "2926013880ffffff2a040402030406005090030404020304060150900350900302030406005090030c2f383838383838383838383838383838382a",
    "04010103042a040101030406005090030c",
    "bd03afadec040bc547f9658668b1ff00000073001f101a37f54cc07fb4bc03bc039a18fbee063690033838383838383838383838383838383838383838383838383838383838",
    "2a040402030406005090030406ffff",
    "29260100094f81800e0000003880ffffff2a0404020304060050900304040203040404020304060050900304040203040601509003509003020406",
    "38060606383838380606060600802a2438380606060600802a047f0000012a163c803c3c3c0606060680ffff002a0404020304380600509003040402030406015090035e2a2a2a2a2a2a2a2a",
    "38060606060606060606060600802a2a2a047f0000012a063c803c3c3c383838012a063c80385fffffff2a260402030406005090030404020304060150900350",
    "a503220000000000000000000000000000000002003880ffffff2a040402030406005090030404020304060150900350900302030406005090030c",
    "047f0000012a2a2a2a2a2a2a2a2a2a2a2a2a2a2a062a2a042a8000142a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a50900350900302030406005090030c2f622f00000203040600030406005090030c2f612f2a712f63030406005090030c2f612f2a622f632a2a002a2a2a2a2a2a372a",
    "047f000001062a2a042a8000142a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2ad52a2a2a2a2a2a2a2a2a2a50900350900302030406005090030c2f622f00000203040600030406005090030c2f612f2a622f63030406005090030c2f612f2a622f632a2a002a2a2a2a2a2a37d52a2a2a2a2a2a2a2a2a2a5090032a",
    "90030c2a04",
  ]

suite "MultiAddress test suite":
  test "go-multiaddr success test vectors":
    for item in SuccessVectors:
      var a = MultiAddress.init(item).get()
      check a.isEmpty() == false
      check a.validate() == true

  test "go-multiaddr failure test vectors":
    for item in FailureVectors:
      check MultiAddress.init(item).isErr()
      check MultiAddress.init(item.toBytes()).isErr()

  test "rust-multiaddr success test vectors":
    ## Rust test vectors are with changed UDP encoding and without WSS
    for i in 0 ..< len(RustSuccessVectors):
      var a = MultiAddress.init(RustSuccessVectors[i]).get()
      check:
        hex(a) == RustSuccessExpects[i]

  test "rust-multiaddr failure test vectors":
    for item in RustFailureVectors:
      check MultiAddress.init(item).isErr()

  test "Concatenation test":
    var ma1 = MultiAddress.init()
    var ma2 = MultiAddress.init()
    var ma3 = MultiAddress.init("/ip4/127.0.0.1").get()
    var ma4 = MultiAddress.init("/udp/30000").get()
    var ma5 = MultiAddress.init("/p2p-circuit").get()
    var cma = ma1 & ma3 & ma4 & ma5
    ma2 &= ma3
    ma2 &= ma4
    ma2 &= ma5
    check:
      $cma == "/ip4/127.0.0.1/udp/30000/p2p-circuit"
      $ma2 == "/ip4/127.0.0.1/udp/30000/p2p-circuit"

  test "Path addresses serialization/deserialization":
    for i in 0 ..< len(PathVectors):
      var a = MultiAddress.init(PathVectors[i]).get()
      check:
        hex(a) == PathExpects[i]
        $a == PathVectors[i]

  test "MultiAddress pattern matching test vectors":
    for item in PatternVectors:
      for gitem in item.good:
        var a = MultiAddress.init(gitem).get()
        check item.pattern.match(a) == true
      for bitem in item.bad:
        var a = MultiAddress.init(bitem).get()
        check item.pattern.match(a) == false

  test "MultiAddress init(\"tcp/udp/dccp/sctp\", int) test":
    check:
      $MultiAddress.init(multiCodec("tcp"), 0).get() == "/tcp/0"
      $MultiAddress.init(multiCodec("tcp"), 65535).get() == "/tcp/65535"
      $MultiAddress.init(multiCodec("tcp"), 34000).get() == "/tcp/34000"
      $MultiAddress.init(multiCodec("udp"), 0).get() == "/udp/0"
      $MultiAddress.init(multiCodec("udp"), 65535).get() == "/udp/65535"
      $MultiAddress.init(multiCodec("udp"), 34000).get() == "/udp/34000"
      $MultiAddress.init(multiCodec("dccp"), 0).get() == "/dccp/0"
      $MultiAddress.init(multiCodec("dccp"), 65535).get() == "/dccp/65535"
      $MultiAddress.init(multiCodec("dccp"), 34000).get() == "/dccp/34000"
      $MultiAddress.init(multiCodec("sctp"), 0).get() == "/sctp/0"
      $MultiAddress.init(multiCodec("sctp"), 65535).get() == "/sctp/65535"
      $MultiAddress.init(multiCodec("sctp"), 34000).get() == "/sctp/34000"

    check:
      MultiAddress.init(multiCodec("ip4"), 0).isErr()
      MultiAddress.init(multiCodec("ip6"), 0).isErr()
      MultiAddress.init(multiCodec("p2p"), 0).isErr()
      MultiAddress.init(multiCodec("tcp"), 65536).isErr()
      MultiAddress.init(multiCodec("udp"), 65536).isErr()
      MultiAddress.init(multiCodec("dccp"), 65536).isErr()
      MultiAddress.init(multiCodec("sctp"), 65536).isErr()
      MultiAddress.init(multiCodec("tcp"), -1).isErr()
      MultiAddress.init(multiCodec("udp"), -1).isErr()
      MultiAddress.init(multiCodec("dccp"), -1).isErr()
      MultiAddress.init(multiCodec("sctp"), -1).isErr()

  test "MultiAddress protoAddress(fixed) test":
    var
      address_v4: array[4, byte]
      address_v6: array[16, byte]
    check:
      MultiAddress.init("/ip4/0.0.0.0").get().protoAddress().get() == address_v4
      MultiAddress.init("/ip6/::0").get().protoAddress().get() == address_v6

  test "MultiAddress getParts":
    let ma = MultiAddress
      .init(
        "/ip4/0.0.0.0/tcp/0/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/p2p-circuit/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSuNEXT/unix/stdio/"
      )
      .get()
    check:
      $ma[0 .. 0].get() == "/ip4/0.0.0.0"
      $ma[^1].get() == "/unix/stdio"
      ma[-100].isErr()
      ma[100].isErr()
      ma[^100].isErr()
      ma[^0].isErr()
      $ma[0 .. 1].get() == "/ip4/0.0.0.0/tcp/0"
      $ma[1 .. 2].get() == "/tcp/0/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
      $ma[^3 ..^ 1].get() ==
        "/p2p-circuit/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSuNEXT/unix/stdio"
      ma[5 .. 7].isErr()

  test "[](MultiCodec) test":
    let onionMAStr =
      "/onion3/torchdeedp3i2jigzjdmfpn5ttjhthh5wbmda2rr3jvqjg5p77c54dqd:80"
    let ma = MultiAddress.init(onionMAStr).get()
    check $(ma[multiCodec("onion3")].tryGet()) == onionMAStr

    let onionMAWithTcpStr =
      "/onion3/torchdeedp3i2jigzjdmfpn5ttjhthh5wbmda2rr3jvqjg5p77c54dqd:80/tcp/80"
    let maWithTcp = MultiAddress.init(onionMAWithTcpStr).get()
    check $(maWithTcp[multiCodec("onion3")].tryGet()) == onionMAStr

  test "matchPartial":
    const tcp = mapEq("tcp")
    let ma = MultiAddress.init("/ip4/0.0.0.0/tcp/0").get()

    check not tcp.matchPartial(ma)
    check IP4.matchPartial(ma)

  test "getRepeatedField does not fail when all addresses are valid":
    var pb = initProtoBuffer()
    let mas = SuccessVectors.mapIt(MultiAddress.init(it).get())
    for ma in mas:
      pb.write(1, ma)
    pb.finish()

    var decoded = newSeq[MultiAddress]()
    check pb.getRepeatedField(1, decoded).isOk()
    check decoded == mas

  test "getRepeatedField does not fail when some addresses are invalid":
    var pb = initProtoBuffer()
    var mas = @[MultiAddress.init("/ip4/1.2.3.4").get(), MultiAddress()]
    for ma in mas:
      pb.write(1, ma)
    pb.finish()

    var decoded = newSeq[MultiAddress]()
    check pb.getRepeatedField(1, decoded).isOk()
    check decoded == @[MultiAddress.init("/ip4/1.2.3.4").get()]

  test "getRepeatedField fails when all addresses are invalid":
    var pb = initProtoBuffer()
    var mas = @[MultiAddress(), MultiAddress()]
    for ma in mas:
      pb.write(1, ma)
    pb.finish()

    var decoded = newSeq[MultiAddress]()
    let error = pb.getRepeatedField(1, decoded).error()
    check error == ProtoError.IncorrectBlob
    check decoded.len == 0

  test "MultiAddress with empty path test":
    for item in ZeroPathFailureVectors:
      let res = MultiAddress.init(hexToSeqByte(item))
      check res.isErr()

  test "MultiAddress crash test":
    for item in CrashesVectors:
      let res = MultiAddress.init(hexToSeqByte(item))
      check res.isErr()
