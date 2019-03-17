import unittest, strutils
import ../libp2p/ipnet/ipnet

const MaskVectors = [
  ["192.168.1.127:1024", "255.255.255.128", "192.168.1.0:1024"],
  ["192.168.1.127:1024", "255.255.255.192", "192.168.1.64:1024"],
  ["192.168.1.127:1024", "255.255.255.224", "192.168.1.96:1024"],
  ["192.168.1.127:1024", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ff80",
   "192.168.1.0:1024"],
  ["192.168.1.127:1024", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffc0",
   "192.168.1.64:1024"],
  ["192.168.1.127:1024", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffe0",
   "192.168.1.96:1024"],
  ["192.168.1.127:1024", "255.0.255.0", "192.0.1.0:1024"],
  ["[2001:db8::1]:1024", "ffff:ff80::", "[2001:d80::]:1024"],
  ["[2001:db8::1]:1024", "f0f0:0f0f::", "[2000:d08::]:1024"]
]

const NonCanonicalMasks = [
  ["ip", "0.255.255.255", "-1"],
  ["ip", "255.0.255.255", "-1"],
  ["ip", "255.255.0.255", "-1"],
  ["ip", "255.255.255.0", "24"],
  ["ms", "0FFFFFFF", "-1"],
  ["ms", "F0FFFFFF", "-1"],
  ["ms", "FF0FFFFF", "-1"],
  ["ms", "FFF0FFFF", "-1"],
  ["ms", "FFFF0FFF", "-1"],
  ["ms", "FFFFF0FF", "-1"],
  ["ms", "FFFFFF0F", "-1"],
  ["ms", "FFFFFFF0", "28"],
  ["ip", "00FF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FF00:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:00FF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FF00:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:00FF:FFFF:FFFF:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FF00:FFFF:FFFF:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:00FF:FFFF:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:FF00:FFFF:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:FFFF:00FF:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:FFFF:FF00:FFFF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:FFFF:FFFF:00FF:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:FFFF:FFFF:FF00:FFFF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:00FF:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FF00:FFFF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:00FF", "-1"],
  ["ip", "FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FF00", "120"],
  ["ms", "0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "F0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FF0FFFFFFFFFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFF0FFFFFFFFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFF0FFFFFFFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFF0FFFFFFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFF0FFFFFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFF0FFFFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFF0FFFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFF0FFFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFF0FFFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFF0FFFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFF0FFFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFF0FFFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFF0FFFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFF0FFFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFF0FFFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFF0FFFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFF0FFFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFF0FFFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFF0FFFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFF0FFFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFF0FFFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFFF0FFFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFFFF0FFFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFFFFF0FFFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFFFFFF0FFFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFFFFFFF0FFFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFFFFFFFF0FFF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFFFFFFFFF0FF", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0F", "-1"],
  ["ms", "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0", "124"],
]

const NetworkVectors = [
  ["135.104.0.0/32", "true", "135.104.0.0:0", "FFFFFFFF"],
  ["0.0.0.0/24", "true", "0.0.0.0:0", "FFFFFF00"],
  ["135.104.0.0/24", "true", "135.104.0.0:0", "FFFFFF00"],
  ["135.104.0.1/32", "true", "135.104.0.1:0", "FFFFFFFF"],
  ["135.104.0.1/24", "true", "135.104.0.1:0", "FFFFFF00"],
  ["::1/128", "true", "[::1]:0", "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"],
  ["abcd:2345::/127", "true", "[abcd:2345::]:0",
   "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE"],
  ["abcd:2345::/65", "true", "[abcd:2345::]:0",
   "FFFFFFFFFFFFFFFF8000000000000000"],
  ["abcd:2345::/64", "true", "[abcd:2345::]:0",
   "FFFFFFFFFFFFFFFF0000000000000000"],
  ["abcd:2345::/63", "true", "[abcd:2345::]:0",
   "FFFFFFFFFFFFFFFE0000000000000000"],
  ["abcd:2345::/33", "true", "[abcd:2345::]:0",
   "FFFFFFFF800000000000000000000000"],
  ["abcd:2345::/32", "true", "[abcd:2345::]:0",
   "FFFFFFFF000000000000000000000000"],
  ["abcd:2344::/31", "true", "[abcd:2344::]:0",
   "FFFFFFFE000000000000000000000000"],
  ["abcd:2300::/24", "true", "[abcd:2300::]:0",
   "FFFFFF00000000000000000000000000"],
  ["abcd:2345::/24", "true", "[abcd:2345::]:0",
   "FFFFFF00000000000000000000000000"],
  ["2001:db8::/48", "true", "[2001:db8::]:0",
   "FFFFFFFFFFFF00000000000000000000"],
  ["2001:db8::1/48", "true", "[2001:db8::1]:0",
   "FFFFFFFFFFFF00000000000000000000"],
  ["192.168.1.1/255.255.255.0", "true", "192.168.1.1:0", "FFFFFF00"],
  ["192.168.1.1/35", "false", "", ""],
  ["2001:db8::1/-1", "false", "", ""],
  ["2001:db8::1/-0", "false", "", ""],
  ["-0.0.0.0/32", "false", "", ""],
  ["0.-1.0.0/32", "false", "", ""],
  ["0.0.-2.0/32", "false", "", ""],
  ["0.0.0.-3/32", "false", "", ""],
  ["0.0.0.0/-0", "false", "", ""],
  ["", "false", "", ""]
]

const NetworkContainsVectors = [
  ["172.16.1.1:1024", "172.16.0.0/12", "true"],
  ["172.24.0.1:1024", "172.16.0.0/13", "false"],
  ["192.168.0.3:1024", "192.168.0.0/0.0.255.252", "true"],
  ["192.168.0.4:1024", "192.168.0.0/0.255.0.252", "false"],
  ["[2001:db8:1:2::1]:1024", "2001:db8:1::/47", "true"],
  ["[2001:db8:1:2::1]:1024", "2001:db8:2::/47", "false"],
  ["[2001:db8:1:2::1]:1024", "2001:db8:1::/ffff:0:ffff::", "true"],
  ["[2001:db8:1:2::1]:1024", "2001:db8:1::/0:0:0:ffff::", "false"]
]

suite "IP network utilities test suite":

  test "IpMask test vectors":
    for item in MaskVectors:
      var a = initTAddress(item[0])
      var m = IpMask.initIp(item[1])
      var r = a.mask(m)
      check $r == item[2]

  test "IpMask serialization/deserialization test":
    for i in 1..32:
      var m = IpMask.init(AddressFamily.IPv4, i)
      check m.prefix() == i
      var s0x = `$`(m, true)
      var s = $m
      var sip = m.ip()
      var m1 = IpMask.init(s0x)
      var m2 = IpMask.init(s)
      var m3 = IpMask.initIp(sip)
      check:
        m == m1
        m == m2
        m == m3
    for i in 1..128:
      var m = IpMask.init(AddressFamily.IPv6, i)
      check m.prefix() == i
      var s0x = `$`(m, true)
      var s = $m
      var sip = m.ip()
      var m1 = IpMask.init(s0x)
      var m2 = IpMask.init(s)
      var m3 = IpMask.initIp(sip)
      check:
        m == m1
        m == m2
        m == m3

  test "IpMask non-canonical masks":
    for item in NonCanonicalMasks:
      var m: IpMask
      if item[0] == "ip":
        m = IpMask.initIp(item[1])
      elif item[0] == "ms":
        m = IpMask.init(item[1])
      var c = $(m.prefix())
      check:
        c == item[2]

  test "IpNet test vectors":
    for item in NetworkVectors:
      var res: bool
      var inet: IpNet
      try:
        inet = IpNet.init(item[0])
        res = true
      except:
        res = false
      check:
        $res == item[1]
      if res:
        check:
          $inet.host == item[2]
          $inet.mask == $item[3]

  test "IpNet contains test vectors":
    for item in NetworkContainsVectors:
      var a = initTAddress(item[0])
      var n = IpNet.init(item[1])
      var res = a in n
      check:
        $res == item[2]

  test "IpNet serialization/deserialization test":
    var ip4 = initTAddress("192.168.1.0:1024")
    for i in 1..32:
      var net = IpNet.init(ip4, i)
      var s1 = $net
      var net2 = IpNet.init(s1)
      check net == net2

    var ip6 = initTAddress("[8000:f123:f456:cafe::]:1024")
    for i in 1..128:
      var net = IpNet.init(ip6, i)
      var s1 = $net
      var net2 = IpNet.init(s1)
      check net == net2
