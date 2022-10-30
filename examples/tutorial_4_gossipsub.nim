## # GossipSub
##
## In this tutorial, we'll build a simple GossipSub network
## to broadcast the metrics we built in the previous tutorial.
##
## GossipSub is used to broadcast some messages in a network,
## and allows to balance between latency, bandwidth usage,
## privacy and attack resistance.
##
## You'll find a good explanation on how GossipSub works
## [here.](https://docs.libp2p.io/concepts/publish-subscribe/) There are a lot
## of parameters you can tweak to adjust how GossipSub behaves but here we'll
## use the sane defaults shipped with libp2p.
##
## We'll start by creating our metric structure like previously

import chronos
import stew/results

import libp2p
import libp2p/protocols/pubsub/rpc/messages

type
  Metric = object
    name: string
    value: float

  MetricList = object
    hostname: string
    metrics: seq[Metric]

{.push raises: [].}

proc encode(m: Metric): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, m.name)
  result.write(2, m.value)
  result.finish()

proc decode(_: type Metric, buf: seq[byte]): Result[Metric, ProtoError] =
  var res: Metric
  let pb = initProtoBuffer(buf)
  discard ? pb.getField(1, res.name)
  discard ? pb.getField(2, res.value)
  ok(res)

proc encode(m: MetricList): ProtoBuffer =
  result = initProtoBuffer()
  for metric in m.metrics:
    result.write(1, metric.encode())
  result.write(2, m.hostname)
  result.finish()

proc decode(_: type MetricList, buf: seq[byte]): Result[MetricList, ProtoError] =
  var
    res: MetricList
    metrics: seq[seq[byte]]
  let pb = initProtoBuffer(buf)
  discard ? pb.getRepeatedField(1, metrics)

  for metric in metrics:
    res.metrics &= ? Metric.decode(metric)
  ? pb.getRequiredField(2, res.hostname)
  ok(res)

## This is exactly like the previous structure, except that we added
## a `hostname` to distinguish where the metric is coming from.
##
## Now we'll create a small GossipSub network to broadcast the metrics,
## and collect them on one of the node.

type Node = tuple[switch: Switch, gossip: GossipSub, hostname: string]

proc oneNode(node: Node, rng: ref HmacDrbgContext) {.async.} =
  # This procedure will handle one of the node of the network
  node.gossip.addValidator(["metrics"],
    proc(topic: string, message: Message): Future[ValidationResult] {.async.} =
      let decoded = MetricList.decode(message.data)
      if decoded.isErr: return ValidationResult.Reject
      return ValidationResult.Accept
  )
  # This "validator" will attach to the `metrics` topic and make sure
  # that every message in this topic is valid. This allows us to stop
  # propagation of invalid messages quickly in the network, and punish
  # peers sending them.

  # `John` will be responsible to log the metrics, the rest of the nodes
  # will just forward them in the network
  if node.hostname == "John":
    node.gossip.subscribe("metrics",
      proc (topic: string, data: seq[byte]) {.async.} =
        echo MetricList.decode(data).tryGet()
    )
  else:
    node.gossip.subscribe("metrics", nil)

  # Create random metrics 10 times and broadcast them
  for _ in 0..<10:
    await sleepAsync(500.milliseconds)
    var metricList = MetricList(hostname: node.hostname)
    let metricCount = rng[].generate(uint32) mod 4
    for i in 0 ..< metricCount + 1:
      metricList.metrics.add(Metric(
        name: "metric_" & $i,
        value: float(rng[].generate(uint16)) / 1000.0
      ))

    discard await node.gossip.publish("metrics", encode(metricList).buffer)
  await node.switch.stop()

## For our main procedure, we'll create a few nodes, and connect them together.
## Note that they are not all interconnected, but GossipSub will take care of
## broadcasting to the full network nonetheless.
proc main {.async.} =
  let rng = newRng()
  var nodes: seq[Node]

  for hostname in ["John", "Walter", "David", "Thuy", "Amy"]:
    let
      switch = newStandardSwitch(rng=rng)
      gossip = GossipSub.init(switch = switch, triggerSelf = true)
    switch.mount(gossip)
    await switch.start()

    nodes.add((switch, gossip, hostname))

  for index, node in nodes:
    # Connect to a few neighbors
    for otherNodeIdx in index - 1 .. index + 2:
      if otherNodeIdx notin 0 ..< nodes.len or otherNodeIdx == index: continue
      let otherNode = nodes[otherNodeIdx]
      await node.switch.connect(
        otherNode.switch.peerInfo.peerId,
        otherNode.switch.peerInfo.addrs)

  var allFuts: seq[Future[void]]
  for node in nodes:
    allFuts.add(oneNode(node, rng))

  await allFutures(allFuts)

waitFor(main())

## If you run this program, you should see something like:
## ```
## (hostname: "John", metrics: @[(name: "metric_0", value: 42.097), (name: "metric_1", value: 50.99), (name: "metric_2", value: 47.86), (name: "metric_3", value: 5.368)])
## (hostname: "Walter", metrics: @[(name: "metric_0", value: 39.452), (name: "metric_1", value: 15.606), (name: "metric_2", value: 14.059), (name: "metric_3", value: 6.68)])
## (hostname: "David", metrics: @[(name: "metric_0", value: 9.82), (name: "metric_1", value: 2.862), (name: "metric_2", value: 15.514)])
## (hostname: "Thuy", metrics: @[(name: "metric_0", value: 59.038)])
## (hostname: "Amy", metrics: @[(name: "metric_0", value: 55.616), (name: "metric_1", value: 23.52), (name: "metric_2", value: 59.081), (name: "metric_3", value: 2.516)])
## ```
##
## This is John receiving & logging everyone's metrics.
##
## ## Going further
## Building efficient & safe GossipSub networks is a tricky subject. By tweaking the [gossip params](https://status-im.github.io/nim-libp2p/master/libp2p/protocols/pubsub/gossipsub/types.html#GossipSubParams)
## and [topic params](https://status-im.github.io/nim-libp2p/master/libp2p/protocols/pubsub/gossipsub/types.html#TopicParams),
## you can achieve very different properties.
##
## Also see reports for [GossipSub v1.1](https://gateway.ipfs.io/ipfs/QmRAFP5DBnvNjdYSbWhEhVRJJDFCLpPyvew5GwCCB4VxM4)
##
## If you are interested in broadcasting for your application, you may want to use [Waku](https://waku.org/), which builds on top of GossipSub,
## and adds features such as history, spam protection, and light node friendliness.
