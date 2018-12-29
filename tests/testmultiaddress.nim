import unittest
import ../libp2p/multiaddress

const
  SuccessVectors = [
    "/ip4/1.2.3.4",
    "/ip4/0.0.0.0",
    "/ip6/::1",
    "/ip6/2601:9:4f81:9700:803e:ca65:66e8:c21",
    "/ip6/2601:9:4f81:9700:803e:ca65:66e8:c21/udp/1234/quic",
    "/ip6zone/x/ip6/fe80::1",
    "/ip6zone/x%y/ip6/fe80::1",
    "/ip6zone/x%y/ip6/::",
    "/ip6zone/x/ip6/fe80::1/udp/1234/quic",
    "/onion/timaq4ygg2iegci7:1234",
    "/onion/timaq4ygg2iegci7:80/http",
    "/udp/0",
    "/tcp/0",
    "/sctp/0",
    "/udp/1234",
    "/tcp/1234",
    "/sctp/1234",
    "/udp/65535",
    "/tcp/65535",
    "/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/udp/1234/sctp/1234",
    "/udp/1234/udt",
    "/udp/1234/utp",
    "/tcp/1234/http",
    "/tcp/1234/https",
    "/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip4/127.0.0.1/udp/1234",
    "/ip4/127.0.0.1/udp/0",
    "/ip4/127.0.0.1/tcp/1234",
    "/ip4/127.0.0.1/tcp/1234/",
    "/ip4/127.0.0.1/udp/1234/quic",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip4/127.0.0.1/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/unix/a/b/c/d/e",
    "/unix/stdio",
    "/ip4/1.2.3.4/tcp/80/unix/a/b/c/d/e/f",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234/unix/stdio",
    "/ip4/127.0.0.1/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234/unix/stdio",
  ]

  FailureVectors = [
    "/ip4",
    "/ip4/::1",
    "/ip4/fdpsofodsajfdoisa",
    "/ip6",
    "/ip6zone",
    "/ip6zone/",
    "/ip6zone//ip6/fe80::1",
    "/udp",
    "/tcp",
    "/sctp",
    "/udp/65536",
    "/tcp/65536",
    "/quic/65536",
    "/onion/9imaq4ygg2iegci7:80",
    "/onion/aaimaq4ygg2iegci7:80",
    "/onion/timaq4ygg2iegci7:0",
    "/onion/timaq4ygg2iegci7:-1",
    "/onion/timaq4ygg2iegci7",
    "/onion/timaq4ygg2iegci@:666",
    "/udp/1234/sctp",
    "/udp/1234/udt/1234",
    "/udp/1234/utp/1234",
    "/ip4/127.0.0.1/udp/jfodsajfidosajfoidsa",
    "/ip4/127.0.0.1/udp",
    "/ip4/127.0.0.1/tcp/jfodsajfidosajfoidsa",
    "/ip4/127.0.0.1/tcp",
    "/ip4/127.0.0.1/quic/1234",
    "/ip4/127.0.0.1/ipfs",
    "/ip4/127.0.0.1/ipfs/tcp",
    "/ip4/127.0.0.1/p2p",
    "/ip4/127.0.0.1/p2p/tcp",
    "/unix"
  ]

  RustSuccessVectors = [
    "/ip4/1.2.3.4",
    "/ip4/0.0.0.0",
    "/ip6/::1",
    "/ip6/2601:9:4f81:9700:803e:ca65:66e8:c21",
    "/udp/0",
    "/tcp/0",
    "/sctp/0",
    "/udp/1234",
    "/tcp/1234",
    "/sctp/1234",
    "/udp/65535",
    "/tcp/65535",
    "/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/udp/1234/sctp/1234",
    "/udp/1234/udt",
    "/udp/1234/utp",
    "/tcp/1234/http",
    "/tcp/1234/https",
    "/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip4/127.0.0.1/udp/1234",
    "/ip4/127.0.0.1/udp/0",
    "/ip4/127.0.0.1/tcp/1234",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip6/2001:8a0:7ac5:4201:3ac9:86ff:fe31:7095/tcp/8000/ws/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/p2p-webrtc-star/ip4/127.0.0.1/tcp/9090/ws/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/tcp/9090/p2p-circuit/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
  ]

  RustSuccessExpects = [
    "0401020304",
    "0400000000",
    "2900000000000000000000000000000001",
    "29260100094F819700803ECA6566E80C21",
    "91020000",
    "060000",
    "84010000",
    "910204D2",
    "0604D2",
    "840104D2",
    "9102FFFF",
    "06FFFF",
    "A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B",
    "910204D2840104D2",
    "910204D2AD02",
    "910204D2AE02",
    "0604D2E003",
    "0604D2BB03",
    "A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B0604D2",
    "047F000001910204D2",
    "047F00000191020000",
    "047F0000010604D2",
    "047F000001A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B",
    "047F000001A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B0604D2",
    "29200108A07AC542013AC986FFFE317095061F40DD03A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B",
    "9302047F000001062382DD03A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B",
    "047F000001062382A202A503221220D52EBB89D85B02A284948203A62FF28389C57C9F42BEEC4EC20DB76A68911C0B"
  ]

  RustFailureVectors = [
    "/ip4",
    "/ip4/::1",
    "/ip4/fdpsofodsajfdoisa",
    "/ip6",
    "/udp",
    "/tcp",
    "/sctp",
    "/udp/65536",
    "/tcp/65536",
    "/onion/9imaq4ygg2iegci7:80",
    "/onion/aaimaq4ygg2iegci7:80",
    "/onion/timaq4ygg2iegci7:0",
    "/onion/timaq4ygg2iegci7:-1",
    "/onion/timaq4ygg2iegci7",
    "/onion/timaq4ygg2iegci@:666",
    "/udp/1234/sctp",
    "/udp/1234/udt/1234",
    "/udp/1234/utp/1234",
    "/ip4/127.0.0.1/udp/jfodsajfidosajfoidsa",
    "/ip4/127.0.0.1/udp",
    "/ip4/127.0.0.1/tcp/jfodsajfidosajfoidsa",
    "/ip4/127.0.0.1/tcp",
    "/ip4/127.0.0.1/ipfs",
    "/ip4/127.0.0.1/ipfs/tcp",
    "/p2p-circuit/50"
  ]

  UtilitySuccessVectors = [
    "/ip4/127.0.0.1/tcp/1024",
    "/ip4/127.0.0.1/udp/1024",
    "/ip4/0.0.0.0/tcp/1024",
    "/ip4/0.0.0.0/udp/1024",
    "/ip4/255.255.255.255/tcp/65535",
    "/ip4/255.255.255.255/udp/65535",
    "/ip6/::1/tcp/1024",
    "/ip6/::1/udp/1024",
    "/ip6/::/tcp/65535",
    "/ip6/::/udp/65535",
    "/ip6/::/udp/65535",
    "/unix/tmp/test.socket"
  ]

  UtilityFailVectors = [
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/tcp/1234",
    "/ip6/2001:8a0:7ac5:4201:3ac9:86ff:fe31:7095/tcp/8000/ws/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/p2p-webrtc-star/ip4/127.0.0.1/tcp/9090/ws/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC",
    "/ip4/127.0.0.1/udp/1234/quic"
  ]

suite "MultiAddress test suite":

  test "go-multiaddr success test vectors":
    for item in SuccessVectors:
      var a = MultiAddress.init(item)
      check a.isEmpty() == false
      check a.validate() == true

  test "go-multiaddr failure test vectors":
    for item in FailureVectors:
      var r = false
      try:
        var a = MultiAddress.init(item)
      except:
        r = true
      check r == true

  test "rust-multiaddr success test vectors":
    ## Rust test vectors are with changed UDP encoding and without WSS
    for i in 0..<len(RustSuccessVectors):
      var a = MultiAddress.init(RustSuccessVectors[i])
      check:
        hex(a) == RustSuccessExpects[i]

  test "rust-multiaddr failure test vectors":
    for item in RustFailureVectors:
      var r = false
      try:
        var a = MultiAddress.init(item)
      except:
        r = true
      check r == true

  test "Concatenation test":
    var ma1 = MultiAddress.init()
    var ma2 = MultiAddress.init()
    var ma3 = MultiAddress.init("/ip4/127.0.0.1")
    var ma4 = MultiAddress.init("/udp/30000")
    var ma5 = MultiAddress.init("/p2p-circuit")
    var cma = ma1 & ma3 & ma4 & ma5
    ma2 &= ma3
    ma2 &= ma4
    ma2 &= ma5
    check:
      $cma == "/ip4/127.0.0.1/udp/30000/p2p-circuit"
      $ma2 == "/ip4/127.0.0.1/udp/30000/p2p-circuit"

  test "isWire() test":
    for item in UtilitySuccessVectors:
      var a = MultiAddress.init(item)
      check a.isWire() == true
    for item in UtilityFailVectors:
      var a = MultiAddress.init(item)
      check a.isWire() == false
