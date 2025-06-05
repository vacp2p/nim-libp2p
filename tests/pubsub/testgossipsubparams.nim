{.used.}

import unittest2
import chronos
import std/tables
import results

import ../../libp2p/protocols/pubsub/gossipsub/[types]
import ../../libp2p/protocols/pubsub/[gossipsub, pubsubpeer]
import ../../libp2p/[peerid, multiaddress]

suite "GossipSubParams validation":
  proc newDefaultValidParams(): GossipSubParams =
    result = GossipSubParams.init()

  test "default parameters are valid":
    var params = newDefaultValidParams()
    check params.validateParameters().isOk()

  test "dOut fails when equal to dLow":
    const errorMessage =
      "gossipsub: dOut parameter error, Number of outbound connections to keep in the mesh. Must be less than D_lo and at most D/2"
    var params = newDefaultValidParams()
    params.dLow = 4
    params.d = 8
    params.dOut = params.dLow
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "dOut fails when bigger than d/2":
    const errorMessage =
      "gossipsub: dOut parameter error, Number of outbound connections to keep in the mesh. Must be less than D_lo and at most D/2"
    var params = newDefaultValidParams()
    params.dLow = 4
    params.d = 5
    params.dOut = 3
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "dOut succeeds when less than dLow and equals d/2":
    var params = newDefaultValidParams()
    params.dLow = 4
    params.d = 6
    params.dOut = 3
    check params.validateParameters().isOk()

  test "gossipThreshold fails when zero":
    const errorMessage = "gossipsub: gossipThreshold parameter error, Must be < 0"
    var params = newDefaultValidParams()
    params.gossipThreshold = 0.0
    var res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "gossipThreshold succeeds when negative":
    var params = newDefaultValidParams()
    params.gossipThreshold = -0.1
    check params.validateParameters().isOk()

  test "unsubscribeBackoff fails when zero":
    const errorMessage =
      "gossipsub: unsubscribeBackoff parameter error, Must be > 0 seconds"
    var params = newDefaultValidParams()
    params.unsubscribeBackoff = 0.seconds
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "unsubscribeBackoff succeeds when positive":
    var params = newDefaultValidParams()
    params.unsubscribeBackoff = 1.seconds
    check params.validateParameters().isOk()

  test "publishThreshold fails when equal to gossipThreshold":
    const errorMessage =
      "gossipsub: publishThreshold parameter error, Must be < gossipThreshold"
    var params = newDefaultValidParams()
    params.publishThreshold = params.gossipThreshold
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "publishThreshold succeeds when less than gossipThreshold":
    var params = newDefaultValidParams()
    params.publishThreshold = params.gossipThreshold - 1.0
    check params.validateParameters().isOk()

  test "graylistThreshold fails when equal to publishThreshold":
    const errorMessage =
      "gossipsub: graylistThreshold parameter error, Must be < publishThreshold"
    var params = newDefaultValidParams()
    params.graylistThreshold = params.publishThreshold
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "graylistThreshold succeeds when less than publishThreshold":
    var params = newDefaultValidParams()
    params.graylistThreshold = params.publishThreshold - 1.0
    check params.validateParameters().isOk()

  test "acceptPXThreshold fails when negative":
    const errorMessage = "gossipsub: acceptPXThreshold parameter error, Must be >= 0"
    var params = newDefaultValidParams()
    params.acceptPXThreshold = -0.1
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "acceptPXThreshold succeeds when zero":
    var params = newDefaultValidParams()
    params.acceptPXThreshold = 0.0
    check params.validateParameters().isOk()

  test "opportunisticGraftThreshold fails when negative":
    const errorMessage =
      "gossipsub: opportunisticGraftThreshold parameter error, Must be >= 0"
    var params = newDefaultValidParams()
    params.opportunisticGraftThreshold = -0.1
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "opportunisticGraftThreshold succeeds when zero":
    var params = newDefaultValidParams()
    params.opportunisticGraftThreshold = 0.0
    check params.validateParameters().isOk()

  test "decayToZero fails when greater than 0.5":
    const errorMessage =
      "gossipsub: decayToZero parameter error, Should be close to 0.0"
    var params = newDefaultValidParams()
    params.decayToZero = 0.51
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "decayToZero fails when zero":
    const errorMessage =
      "gossipsub: decayToZero parameter error, Should be close to 0.0"
    var params = newDefaultValidParams()
    params.decayToZero = 0.0
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "decayToZero succeeds when exactly 0.5":
    var params = newDefaultValidParams()
    params.decayToZero = 0.5
    check params.validateParameters().isOk()

  test "decayToZero succeeds when small positive value":
    var params = newDefaultValidParams()
    params.decayToZero = 0.00001
    check params.validateParameters().isOk()

  test "appSpecificWeight fails when negative":
    const errorMessage =
      "gossipsub: appSpecificWeight parameter error, Must be positive"
    var params = newDefaultValidParams()
    params.appSpecificWeight = -0.1
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "appSpecificWeight succeeds when zero":
    var params = newDefaultValidParams()
    params.appSpecificWeight = 0.0
    check params.validateParameters().isOk()

  test "ipColocationFactorWeight fails when positive":
    const errorMessage =
      "gossipsub: ipColocationFactorWeight parameter error, Must be negative or 0"
    var params = newDefaultValidParams()
    params.ipColocationFactorWeight = 0.1
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "ipColocationFactorWeight succeeds when zero":
    var params = newDefaultValidParams()
    params.ipColocationFactorWeight = 0.0
    check params.validateParameters().isOk()

  test "ipColocationFactorWeight succeeds when negative":
    var params = newDefaultValidParams()
    params.ipColocationFactorWeight = -10.0
    check params.validateParameters().isOk()

  test "ipColocationFactorThreshold fails when less than 1":
    const errorMessage =
      "gossipsub: ipColocationFactorThreshold parameter error, Must be at least 1"
    var params = newDefaultValidParams()
    params.ipColocationFactorThreshold = 0.9
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "ipColocationFactorThreshold succeeds when exactly 1":
    var params = newDefaultValidParams()
    params.ipColocationFactorThreshold = 1.0
    check params.validateParameters().isOk()

  test "behaviourPenaltyWeight fails when zero":
    const errorMessage =
      "gossipsub: behaviourPenaltyWeight parameter error, Must be negative"
    var params = newDefaultValidParams()
    params.behaviourPenaltyWeight = 0.0
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "behaviourPenaltyWeight succeeds when negative":
    var params = newDefaultValidParams()
    params.behaviourPenaltyWeight = -0.0001
    check params.validateParameters().isOk()

  test "behaviourPenaltyDecay fails when negative":
    const errorMessage =
      "gossipsub: behaviourPenaltyDecay parameter error, Must be between 0 and 1"
    var params = newDefaultValidParams()
    params.behaviourPenaltyDecay = -0.1
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "behaviourPenaltyDecay fails when equal to 1":
    const errorMessage =
      "gossipsub: behaviourPenaltyDecay parameter error, Must be between 0 and 1"
    var params = newDefaultValidParams()
    params.behaviourPenaltyDecay = 1.0
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "behaviourPenaltyDecay succeeds when zero":
    var params = newDefaultValidParams()
    params.behaviourPenaltyDecay = 0.0
    check params.validateParameters().isOk()

  test "behaviourPenaltyDecay succeeds when between 0 and 1":
    var params = newDefaultValidParams()
    params.behaviourPenaltyDecay = 0.5
    check params.validateParameters().isOk()

  test "maxNumElementsInNonPriorityQueue fails when zero":
    const errorMessage =
      "gossipsub: maxNumElementsInNonPriorityQueue parameter error, Must be > 0"
    var params = newDefaultValidParams()
    params.maxNumElementsInNonPriorityQueue = 0
    let res = params.validateParameters()
    check res.isErr()
    check res.error == errorMessage

  test "maxNumElementsInNonPriorityQueue succeeds when positive":
    var params = newDefaultValidParams()
    params.maxNumElementsInNonPriorityQueue = 1
    check params.validateParameters().isOk()
