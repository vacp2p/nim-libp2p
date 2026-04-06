# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results
import ../../../../libp2p/[protocols/mix, protocols/mix/mix_protocol, switch, builders]

import ../../../tools/[lifecycle, unittest]
import ../utils

suite "Mix Protocol - Connection API":
  asyncTeardown:
    checkTrackers()

  asyncTest "send fails when pool has not enough nodes":
    let nodes = await setupMixNodes(3) # each node's pool = 2 peers (< PathLength)
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0].toConnection(destNode.toMixDestination(), nrProto.codec).expect(
        "could not build connection"
      )
    defer:
      await conn.close()

    expect LPStreamError:
      await conn.writeLp(@[1.byte, 2, 3])

  asyncTest "toConnection rejects expectReply without destReadBehavior":
    let nodes = await setupMixNodes(10) # no destReadBehavior registered
    startAndDeferStop(nodes)

    # No destination protocol needed — toConnection should fail
    let destNode = createSwitch()
    await destNode.start()
    defer:
      await destNode.stop()

    let conn = nodes[0].toConnection(
      destNode.toMixDestination(),
      "/test/codec",
      MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
    )

    check:
      conn.isErr
      conn.error == "no destination read behavior for codec"

  asyncTest "read from write-only connection raises error":
    let nodes = await setupMixNodes(10)
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0]
      .toConnection(
        destNode.toMixDestination(),
        nrProto.codec, # no expectReply, connection is write-only
      )
      .expect("could not build connection")
    defer:
      await conn.close()

    expect LPStreamError:
      discard await conn.readLp(1024)

  asyncTest "write rejects oversized messages":
    let nodes = await setupMixNodes(10)
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0].toConnection(destNode.toMixDestination(), nrProto.codec).expect(
        "could not build connection"
      )
    defer:
      await conn.close()

    # Write a message at exactly the maximum allowed size — should succeed
    let maxMessageSize = getMaxMessageSizeForCodec(nrProto.codec, 0).get()
    await conn.write(newSeq[byte](maxMessageSize))

    # Write a message one byte over the limit — should be rejected
    expect LPStreamError:
      await conn.write(newSeq[byte](maxMessageSize + 1))
