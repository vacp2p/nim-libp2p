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

  test "initial mode follows the configured mode":
    check:
      setupKad(mode = KadMode.Server).mode == KadMode.Server
      setupKad(mode = KadMode.Client).mode == KadMode.Client
      setupKad(mode = KadMode.Auto).mode == KadMode.Client # client until reachable

  test "changeMode reports whether the mode changed":
    let kad = setupKad(mode = KadMode.Client)

    check (waitFor kad.changeMode(KadMode.Server))
    check kad.mode == KadMode.Server

    # Same mode twice changes nothing, and Auto is a configuration value only.
    check not (waitFor kad.changeMode(KadMode.Server))
    check not (waitFor kad.changeMode(KadMode.Auto))
    check kad.mode == KadMode.Server

    check (waitFor kad.changeMode(KadMode.Client))
    check kad.mode == KadMode.Client

  test "onReachabilityChanged only drives a node configured as Auto":
    let auto = setupKad(mode = KadMode.Auto)
    waitFor auto.onReachabilityChanged(NetworkReachability.Reachable)
    check auto.mode == KadMode.Server
    waitFor auto.onReachabilityChanged(NetworkReachability.NotReachable)
    check auto.mode == KadMode.Client
    waitFor auto.onReachabilityChanged(NetworkReachability.Unknown)
    check auto.mode == KadMode.Client # Unknown leaves the current mode untouched

    # Pinned modes ignore reachability changes.
    let server = setupKad(mode = KadMode.Server)
    waitFor server.onReachabilityChanged(NetworkReachability.NotReachable)
    check server.mode == KadMode.Server

    let client = setupKad(mode = KadMode.Client)
    waitFor client.onReachabilityChanged(NetworkReachability.Reachable)
    check client.mode == KadMode.Client

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

    check (await server.changeMode(KadMode.Client))
    check (await querier.dialFindNode(server)).isNone()

    check (await server.changeMode(KadMode.Server))
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

    check (await server.changeMode(KadMode.Client))
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
