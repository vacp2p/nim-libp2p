# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, stew/byteutils
import
  ../../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_protocol,
    protocols/mix/serialization,
    switch,
    builders,
  ]

import ../../../tools/[lifecycle, unittest]
import ../utils
import ../mock_mix

suite "Mix Protocol - Security":
  asyncTeardown:
    checkTrackers()

  asyncTest "no response sent back on failure":
    let nodes = await setupMixNodes(2)
    startAndDeferStop(nodes)

    let targetPeerId = nodes[1].switch.peerInfo.peerId
    let targetAddr = nodes[1].switch.peerInfo.addrs[0]

    # Dial the mix node directly
    let conn = await nodes[0].switch.dial(targetPeerId, @[targetAddr], @[MixProtocolID])
    defer:
      await conn.close()

    # Send a "corrupted packet" - raw bytes that are not initialized according to the MixMessage structure
    await conn.writeLp(newSeq[byte](PacketSize))

    # Wait briefly to give the mix node time to process, then try to read.
    # Assert that MixProtocol doesn't send any information back in case of a failure.
    expect AsyncTimeoutError:
      var buf = newSeq[byte](1)
      await conn.readExactly(addr buf[0], 1).wait(1.seconds)

  asyncTest "replay protection - duplicate packet is silently dropped":
    ## Use mock to capture real Sphinx packet, then replay it.
    ## The second one must be silently dropped.
    ## With 4 nodes and node 1 as a sender, mock is guaranteed to be in the path.
    let (nodes, mock) = await setupMixNodesWithMock(4)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    await startNodes(nodes)
    defer:
      await stopNodes(nodes)

    let conn = nodes[1].toConnection(destNode.toMixDestination(), nrProto.codec).expect(
        "could not build connection"
      )

    let testPayload = "forward message".toBytes()
    await conn.writeLp(testPayload)
    await conn.close()

    let receivedMsg = await nrProto.receivedMessages.get().wait(5.seconds)
    check receivedMsg.data == testPayload

    # Replay: send the exact same bytes to the mock again (who is the sender doesn't matter)
    let rawConn = await nodes[1].switch.dial(
      mock.switch.peerInfo.peerId, @[mock.switch.peerInfo.addrs[0]], @[MixProtocolID]
    )
    defer:
      await rawConn.close()

    check mock.capturedBytes.len > 0
    await rawConn.writeLp(mock.capturedBytes)

    # Destination must not receive a second message
    expect AsyncTimeoutError:
      discard await nrProto.receivedMessages.get().wait(2.seconds)
