## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import unittest, options, tables, sugar, sequtils
import chronos, chronicles
import ../libp2p/[switch,
                  multistream,
                  protocols/identify,
                  connection,
                  transports/transport,
                  transports/tcptransport,
                  multiaddress,
                  peerinfo,
                  crypto/crypto,
                  peer,
                  protocols/protocol,
                  muxers/muxer,
                  muxers/mplex/mplex,
                  muxers/mplex/types,
                  protocols/secure/secure,
                  protocols/secure/secio,
                  protocols/pubsub/pubsub,
                  protocols/pubsub/floodsub]

proc createMplex(conn: Connection): Muxer =
  result = newMplex(conn)

proc createNode(privKey: Option[PrivateKey] = none(PrivateKey), 
                address: string = "/ip4/127.0.0.1/tcp/0"): Switch = 
  var peerInfo: PeerInfo
  var seckey = privKey
  if privKey.isNone:
    seckey = some(PrivateKey.random(RSA))

  peerInfo.peerId = some(PeerID.init(seckey.get()))
  peerInfo.addrs.add(Multiaddress.init(address))

  let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  let transports = @[Transport(newTransport(TcpTransport))]
  let muxers = [(MplexCodec, mplexProvider)].toTable()
  let identify = newIdentify(peerInfo)
  let secureManagers = [(SecioCodec, Secure(newSecio(seckey.get())))].toTable()
  let pubSub = some(PubSub(newFloodSub(peerInfo)))
  result = newSwitch(peerInfo,
                     transports,
                     identify,
                     muxers,
                     secureManagers = secureManagers,
                     pubSub = pubSub)

proc generateNodes*(num: Natural): seq[Switch] =
  for i in 0..<num:
    result.add(createNode())

proc subscribeNodes*(nodes: seq[Switch]) {.async.} = 
  var pending: seq[Future[void]]
  for dialer in nodes:
    for node in nodes:
      pending.add(dialer.subscribeToPeer(node.peerInfo))
  await allFutures(pending)

suite "PubSub":
  test "FloodSub basic publish/subscribe A -> B": 
    proc testBasicPubSub(): Future[bool] {.async.} =
      var passed: bool
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
        check topic == "foobar"
        passed = true

      var nodes = generateNodes(2)
      var wait = await nodes[1].start()

      await nodes[0].subscribeToPeer(nodes[1].peerInfo)

      await nodes[1].subscribe("foobar", handler)
      await sleepAsync(100.millis)

      await nodes[0].publish("foobar", cast[seq[byte]]("Hello!"))
      await sleepAsync(100.millis)

      await nodes[1].stop()
      await allFutures(wait)
      result = passed

    check:
      waitFor(testBasicPubSub()) == true

  test "FloodSub basic publish/subscribe B -> A":
    proc testBasicPubSub(): Future[bool] {.async.} =
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
        check topic == "foobar"

      var nodes = generateNodes(2)
      var wait = await nodes[1].start()

      await nodes[0].subscribeToPeer(nodes[1].peerInfo)

      await nodes[0].subscribe("foobar", handler)
      await sleepAsync(10.millis)

      await nodes[1].publish("foobar", cast[seq[byte]]("Hello!"))
      await sleepAsync(10.millis)

      await nodes[1].stop()
      await allFutures(wait)
      result = true

    check:
      waitFor(testBasicPubSub()) == true

  test "basic FloodSub": 
    proc testBasicFloodSub(): Future[bool] {.async.} =
      var passed: int
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} = 
        check topic == "foobar"
        passed.inc()

      var nodes: seq[Switch] = generateNodes(20)
      var awaitters: seq[Future[void]]
      for node in nodes:
        awaitters.add(await node.start())
        await node.subscribe("foobar", handler)
        await sleepAsync(10.millis)

      await subscribeNodes(nodes)
      await sleepAsync(50.millis)

      for node in nodes:
        await node.publish("foobar", cast[seq[byte]]("Hello!"))
        await sleepAsync(100.millis)

      await allFutures(nodes.mapIt(it.stop()))
      await allFutures(awaitters)

      result = passed == 20

    check:
      waitFor(testBasicFloodSub()) == true
