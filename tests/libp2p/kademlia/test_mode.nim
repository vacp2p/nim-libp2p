# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../../libp2p/[protocols/kademlia, switch]
import ../../tools/[lifecycle, unittest]
import ./utils

proc dialFindNode(
    querier, target: KadDHT
): Future[Opt[Message]] {.async: (raises: [CancelledError]).} =
  ## Dial the target's Kad codec, send a FIND_NODE and return the reply, or
  ## `Opt.none` when the target refuses to serve (stream reset, no reply).
  let stream =
    try:
      await querier.switch.dial(
        target.switch.peerInfo.peerId, target.switch.peerInfo.addrs, querier.codec
      )
    except CatchableError:
      return Opt.none(Message)
  defer:
    await stream.close()

  let msg = Message(
    msgType: Opt.some(MessageType.findNode), key: Opt.some(target.rtable.selfId)
  )
  try:
    await stream.writeLp(msg.encode(querier.config.hideConnectionStatus))
    let replyBuf = await stream.readLp(MaxMsgSize).wait(1.seconds)
    let reply = Message.decode(replyBuf).valueOr:
      return Opt.none(Message)
    # A served query yields a well-formed FIND_NODE reply; anything else is a
    # broken server masquerading as one, so do not count it as served.
    if reply.msgType != Opt.some(MessageType.findNode):
      return Opt.none(Message)
    return Opt.some(reply)
  except CatchableError:
    return Opt.none(Message)

suite "KadDHT dynamic mode":
  teardown:
    checkTrackers()

  test "initial serving state follows the configured mode":
    check:
      setupKad(mode = KadMode.Server).isServer()
      not setupKad(mode = KadMode.Client).isServer()
      not setupKad(mode = KadMode.Auto).isServer() # client until reachable

  test "moveToServerMode/moveToClientMode flip the serving flag":
    let kad = setupKad(mode = KadMode.Client)
    check not kad.isServer()

    kad.moveToServerMode()
    check kad.isServer()

    waitFor kad.moveToClientMode()
    check not kad.isServer()

  test "onReachabilityChanged only drives Auto mode":
    let auto = setupKad(mode = KadMode.Auto)
    waitFor auto.onReachabilityChanged(NetworkReachability.Reachable)
    check auto.isServer()
    waitFor auto.onReachabilityChanged(NetworkReachability.NotReachable)
    check not auto.isServer()
    waitFor auto.onReachabilityChanged(NetworkReachability.Unknown)
    check not auto.isServer() # Unknown leaves the current mode untouched

    # Pinned modes ignore reachability changes.
    let server = setupKad(mode = KadMode.Server)
    waitFor server.onReachabilityChanged(NetworkReachability.NotReachable)
    check server.isServer()

    let client = setupKad(mode = KadMode.Client)
    waitFor client.onReachabilityChanged(NetworkReachability.Reachable)
    check not client.isServer()

  asyncTest "server answers queries, client resets them":
    let querier = setupKad()
    let server = setupKad(mode = KadMode.Server)
    let client = setupKad(mode = KadMode.Client)
    startAndDeferStop(@[querier, server, client])

    check (await querier.dialFindNode(server)).isSome()
    check (await querier.dialFindNode(client)).isNone()

  asyncTest "downgrade to client mode stops serving and drops peers":
    let querier = setupKad()
    let server = setupKad(mode = KadMode.Server)
    startAndDeferStop(@[querier, server])

    check (await querier.dialFindNode(server)).isSome()

    await server.moveToClientMode()
    check (await querier.dialFindNode(server)).isNone()

    server.moveToServerMode()
    check (await querier.dialFindNode(server)).isSome()

  asyncTest "downgrade resets an in-flight inbound stream":
    let querier = setupKad()
    let server = setupKad(mode = KadMode.Server)
    startAndDeferStop(@[querier, server])

    let stream = await querier.switch.dial(
      server.switch.peerInfo.peerId, server.switch.peerInfo.addrs, querier.codec
    )
    defer:
      await stream.close()

    # One round-trip parks the server handler on the next read, so the stream is
    # held open and tracked as a server stream.
    let msg = Message(
      msgType: Opt.some(MessageType.findNode), key: Opt.some(server.rtable.selfId)
    )
    await stream.writeLp(msg.encode(querier.config.hideConnectionStatus))
    discard await stream.readLp(MaxMsgSize).wait(1.seconds)

    checkUntilTimeout:
      server.serverStreams.len == 1

    await server.moveToClientMode()
    check server.serverStreams.len == 0

    # The downgrade must reset the parked stream: the querier's next read ends in
    # EOF, not a timeout (a timeout would mean the reset never propagated).
    var gotEof = false
    try:
      discard await stream.readLp(MaxMsgSize).wait(3.seconds)
    except AsyncTimeoutError:
      gotEof = false
    except CatchableError:
      gotEof = true
    check gotEof
