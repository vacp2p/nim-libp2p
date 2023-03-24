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
    let maIP4 = MultiAddress.init("/ip4/0.0.0.0/tcp/80").get()

    check:
      observedAddrManager.addObservation(mostObservedIP4AndPort)
      observedAddrManager.addObservation(mostObservedIP4AndPort)

      observedAddrManager.tryReplaceFirstProtoValueByMostObserved(maIP4) == maIP4

      observedAddrManager.addObservation(MultiAddress.init("/ip4/1.2.3.0/tcp/2").get())
      observedAddrManager.addObservation(MultiAddress.init("/ip4/1.2.3.1/tcp/1").get())

      observedAddrManager.tryReplaceFirstProtoValueByMostObserved(maIP4) == MultiAddress.init("/ip4/1.2.3.0/tcp/80").get()
      observedAddrManager.getMostObservedProtosAndPorts().len == 0

      observedAddrManager.addObservation(mostObservedIP4AndPort)

      observedAddrManager.getMostObservedProtosAndPorts() == @[mostObservedIP4AndPort]

    # Calculate the most oberserved IP6 correctly
    let mostObservedIP6AndPort = MultiAddress.init("/ip6/::2/tcp/1").get()
    let maIP6 = MultiAddress.init("/ip6/::1/tcp/80").get()

    check:
      observedAddrManager.addObservation(mostObservedIP6AndPort)
      observedAddrManager.addObservation(mostObservedIP6AndPort)

      observedAddrManager.tryReplaceFirstProtoValueByMostObserved(maIP6) == maIP6

      observedAddrManager.addObservation(MultiAddress.init("/ip6/::2/tcp/2").get())
      observedAddrManager.addObservation(MultiAddress.init("/ip6/::3/tcp/1").get())

      observedAddrManager.tryReplaceFirstProtoValueByMostObserved(maIP6) == MultiAddress.init("/ip6/::2/tcp/80").get()
      observedAddrManager.getMostObservedProtosAndPorts().len == 1

      observedAddrManager.addObservation(mostObservedIP6AndPort)

      observedAddrManager.getMostObservedProtosAndPorts() == @[mostObservedIP4AndPort, mostObservedIP6AndPort]

  asyncTest "replace first proto value by most observed when there is only one protocol":
    let observedAddrManager = ObservedAddrManager.new(minCount = 3)
    let mostObservedIP4AndPort = MultiAddress.init("/ip4/1.2.3.4/tcp/1").get()

    check:
      observedAddrManager.addObservation(mostObservedIP4AndPort)
      observedAddrManager.addObservation(mostObservedIP4AndPort)
      observedAddrManager.addObservation(mostObservedIP4AndPort)

      observedAddrManager.tryReplaceFirstProtoValueByMostObserved(
        MultiAddress.init("/ip4/0.0.0.0").get()) == MultiAddress.init("/ip4/1.2.3.4").get()
