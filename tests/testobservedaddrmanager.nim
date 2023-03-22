import unittest2,
      ../libp2p/multiaddress,
      ../libp2p/observedaddrmanager,
      ./helpers

suite "ObservedAddrManager":
  teardown:
    checkTrackers()

  asyncTest "Calculate the most oberserved IP correctly":

    let observedAddrManager = ObservedAddrManager.new(minCount = 3)

    # Calculate the most oberserved IP4 correctly
    let mostObservedIP4AndPort = MultiAddress.init("/ip4/1.2.3.0/tcp/1").get()

    observedAddrManager.addObservation(mostObservedIP4AndPort)
    observedAddrManager.addObservation(mostObservedIP4AndPort)

    check observedAddrManager.getMostObservedIP(IpAddressFamily.IPv4).isNone()
    check observedAddrManager.getMostObservedIP(IpAddressFamily.IPv6).isNone()

    observedAddrManager.addObservation(MultiAddress.init("/ip4/1.2.3.0/tcp/2").get())
    observedAddrManager.addObservation(MultiAddress.init("/ip4/1.2.3.1/tcp/1").get())

    check observedAddrManager.getMostObservedIP(IpAddressFamily.IPv4).get() == MultiAddress.init("/ip4/1.2.3.0").get()
    check observedAddrManager.getMostObservedIPAndPort(IpAddressFamily.IPv4).isNone()

    observedAddrManager.addObservation(mostObservedIP4AndPort)

    check observedAddrManager.getMostObservedIPAndPort(IpAddressFamily.IPv4).get() == mostObservedIP4AndPort

    # Calculate the most oberserved IP6 correctly
    let mostObservedIP6AndPort = MultiAddress.init("/ip6/::1/tcp/1").get()

    observedAddrManager.addObservation(mostObservedIP6AndPort)
    observedAddrManager.addObservation(mostObservedIP6AndPort)

    check observedAddrManager.getMostObservedIP(IpAddressFamily.IPv6).isNone()

    observedAddrManager.addObservation(MultiAddress.init("/ip6/::1/tcp/2").get())
    observedAddrManager.addObservation(MultiAddress.init("/ip6/::2/tcp/1").get())

    check observedAddrManager.getMostObservedIP(IpAddressFamily.IPv6).get() == MultiAddress.init("/ip6/::1").get()
    check observedAddrManager.getMostObservedIPAndPort(IpAddressFamily.IPv6).isNone()

    observedAddrManager.addObservation(mostObservedIP6AndPort)

    check observedAddrManager.getMostObservedIPAndPort(IpAddressFamily.IPv6).get() == mostObservedIP6AndPort
