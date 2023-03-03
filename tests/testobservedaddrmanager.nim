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

    observedAddrManager.add(mostObservedIP4AndPort)
    observedAddrManager.add(mostObservedIP4AndPort)

    check observedAddrManager.getMostObservedIP4().isNone()

    observedAddrManager.add(MultiAddress.init("/ip4/1.2.3.0/tcp/2").get())
    observedAddrManager.add(MultiAddress.init("/ip4/1.2.3.1/tcp/1").get())

    check observedAddrManager.getMostObservedIP4().get() == MultiAddress.init("/ip4/1.2.3.0").get()
    check observedAddrManager.getMostObservedIP4AndPort().isNone()

    observedAddrManager.add(mostObservedIP4AndPort)

    check observedAddrManager.getMostObservedIP4AndPort().get() == mostObservedIP4AndPort

    # Calculate the most oberserved IP6 correctly
    let mostObservedIP6AndPort = MultiAddress.init("/ip6/::1/tcp/1").get()

    observedAddrManager.add(mostObservedIP6AndPort)
    observedAddrManager.add(mostObservedIP6AndPort)

    check observedAddrManager.getMostObservedIP6().isNone()

    observedAddrManager.add(MultiAddress.init("/ip6/::1/tcp/2").get())
    observedAddrManager.add(MultiAddress.init("/ip6/::2/tcp/1").get())

    check observedAddrManager.getMostObservedIP6().get() == MultiAddress.init("/ip6/::1").get()
    check observedAddrManager.getMostObservedIP6AndPort().isNone()

    observedAddrManager.add(mostObservedIP6AndPort)

    check observedAddrManager.getMostObservedIP6AndPort().get() == mostObservedIP6AndPort
