import unittest
import ../libp2p/ipnet/iface

suite "OS interfaces list suite":
  test "Get interfaces list test":
    var ifaces = getInterfaces()
    for item in ifaces:
      echo item
    check len(ifaces) > 0
