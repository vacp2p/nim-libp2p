## # Protobuf usage
##
## In the [previous tutorial](tutorial_2_customproto.md), we created a simple "ping" protocol.
## Most real protocol want their messages to be structured and extensible, which is why
## most real protocols use [protobuf](https://developers.google.com/protocol-buffers) to
## define their message structures.
##
## Here, we'll create a slightly more complex protocol, which parses & generate protobuf
## messages. Let's start by importing our dependencies, as usual:
import chronos
import stew/results # for Opt[T]

import libp2p

## ## Protobuf encoding & decoding
## This will be the structure of our messages:
## ```protobuf
## message MetricList {
##   message Metric {
##     string name = 1;
##     float value = 2;
##   }
##
##   repeated Metric metrics = 2;
## }
## ```
## We'll create our protobuf types, encoders & decoders, according to this format.
## To create the encoders & decoders, we are going to use minprotobuf
## (included in libp2p).
##
## While more modern technics
## (such as [nim-protobuf-serialization](https://github.com/status-im/nim-protobuf-serialization))
## exists, minprotobuf is currently the recommended method to handle protobuf, since it has
## been used in production extensively, and audited.
type
  Metric = object
    name: string
    value: float

  MetricList = object
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
  # "getField" will return a Result[bool, ProtoError].
  # The Result will hold an error if the protobuf is invalid.
  # The Result will hold "false" if the field is missing
  #
  # We are just checking the error, and ignoring whether the value
  # is present or not (default values are valid).
  discard ? pb.getField(1, res.name)
  discard ? pb.getField(2, res.value)
  ok(res)

proc encode(m: MetricList): ProtoBuffer =
  result = initProtoBuffer()
  for metric in m.metrics:
    result.write(1, metric.encode())
  result.finish()

proc decode(_: type MetricList, buf: seq[byte]): Result[MetricList, ProtoError] =
  var
    res: MetricList
    metrics: seq[seq[byte]]
  let pb = initProtoBuffer(buf)
  discard ? pb.getRepeatedField(1, metrics)

  for metric in metrics:
    res.metrics &= ? Metric.decode(metric)
  ok(res)

## ## Results instead of exceptions
## As you can see, this part of the program also uses Results instead of exceptions for error handling.
## We start by `{.push raises: [].}`, which will prevent every non-async function from raising
## exceptions.
##
## Then, we use [nim-result](https://github.com/arnetheduck/nim-result) to convey
## errors to function callers. A `Result[T, E]` will either hold a valid result of type
## T, or an error of type E.
##
## You can check if the call succeeded by using `res.isOk`, and then get the
## value using `res.value` or the error by using `res.error`.
##
## Another useful tool is `?`, which will unpack a Result if it succeeded,
## or if it failed, exit the current procedure returning the error.
##
## nim-result is packed with other functionalities that you'll find in the
## nim-result repository.
##
## Results and exception are generally interchangeable, but have different semantics
## that you may or may not prefer.
##
## ## Creating the protocol
## We'll next create a protocol, like in the last tutorial, to request these metrics from our host
type
  MetricCallback = proc: Future[MetricList] {.raises: [], gcsafe.}
  MetricProto = ref object of LPProtocol
    metricGetter: MetricCallback

proc new(_: typedesc[MetricProto], cb: MetricCallback): MetricProto =
  var res: MetricProto
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    let
      metrics = await res.metricGetter()
      asProtobuf = metrics.encode()
    await conn.writeLp(asProtobuf.buffer)
    await conn.close()

  res = MetricProto.new(@["/metric-getter/1.0.0"], handle)
  res.metricGetter = cb
  return res

proc fetch(p: MetricProto, conn: Connection): Future[MetricList] {.async.} =
  let protobuf = await conn.readLp(2048)
  # tryGet will raise an exception if the Result contains an error.
  # It's useful to bridge between exception-world and result-world
  return MetricList.decode(protobuf).tryGet()

## We can now create our main procedure:
proc main() {.async, gcsafe.} =
  let rng = newRng()
  proc randomMetricGenerator: Future[MetricList] {.async.} =
    let metricCount = rng[].generate(uint32) mod 16
    for i in 0 ..< metricCount + 1:
      result.metrics.add(Metric(
        name: "metric_" & $i,
        value: float(rng[].generate(uint16)) / 1000.0
      ))
    return result
  let
    metricProto1 = MetricProto.new(randomMetricGenerator)
    metricProto2 = MetricProto.new(randomMetricGenerator)
    switch1 = newStandardSwitch(rng=rng)
    switch2 = newStandardSwitch(rng=rng)

  switch1.mount(metricProto1)

  await switch1.start()
  await switch2.start()

  let
    conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, metricProto2.codecs)
    metrics = await metricProto2.fetch(conn)
  await conn.close()

  for metric in metrics.metrics:
    echo metric.name, " = ", metric.value

  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports

waitFor(main())

## If you run this program, you should see random metrics being sent from the switch1 to the switch2.
