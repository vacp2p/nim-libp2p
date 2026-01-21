# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[options, sets, tables]
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, extension_test, extension_partial_message]

export PeerCallback, TestExtensionConfig, PartialMessageExtensionConfig

type ExtensionsState* = ref object
  sentExtensions: HashSet[PeerId] # nodes extensions were sent to peer
  peerExtensions: Table[PeerId, PeerExtensions]
    # tells what peer capabilities are (what extensions are supported)
  onMissbehave: PeerCallback
  extensions: seq[Extension]
  nodeExtensions: ControlExtensions # tells what this nodes capabilities are 

proc new*(
    T: typedesc[ExtensionsState],
    onMissbehave: PeerCallback = noopPeerCallback,
    testExtensionConfig: Option[TestExtensionConfig] = none(TestExtensionConfig),
    partialMessageExtensionConfig: Option[PartialMessageExtensionConfig] =
      none(PartialMessageExtensionConfig),
): T =
  var nodeExtensions = ControlExtensions()
  var extensions = newSeq[Extension]()

  testExtensionConfig.withValue(c):
    extensions.add(TestExtension.new(c))
    nodeExtensions.testExtension = some(true)

  partialMessageExtensionConfig.withValue(c):
    extensions.add(PartialMessageExtension.new(c))
    nodeExtensions.partialMessageExtension = some(true)

  T(
    onMissbehave: onMissbehave,
    sentExtensions: initHashSet[PeerId](),
    extensions: extensions,
    nodeExtensions: nodeExtensions,
  )

proc toPeerExtensions(ce: ControlExtensions): PeerExtensions =
  let testExtension = ce.testExtension.valueOr:
    false
  let partialMessageExtension = ce.partialMessageExtension.valueOr:
    false

  PeerExtensions(
    testExtension: testExtension, #
    partialMessageExtension: partialMessageExtension,
  )

proc onHandleRPC(state: ExtensionsState, peerId: PeerId) =
  # extensions event called when node receives every RPC message.

  for _, e in state.extensions:
    if e.isSupported(state.peerExtensions.getOrDefault(peerId)):
      e.onHandleRPC(peerId)

proc onNegotiated(state: ExtensionsState, peerId: PeerId) =
  # extension event called when both sides have negotiated (exchanged) extensions.
  # it will be called only once per connection session as soon as extensiosn are exchanged.

  for _, e in state.extensions:
    if e.isSupported(state.peerExtensions.getOrDefault(peerId)):
      e.onNegotiated(peerId)

proc addPeer*(state: ExtensionsState, peerId: PeerId) =
  # called after peer has connected to node and extensions control message is sent by gossipsub.

  state.sentExtensions.incl(peerId)

  # when node has received control extensions from peer then extensions have negotiated
  if peerId in state.peerExtensions:
    state.onNegotiated(peerId)

proc removePeer*(state: ExtensionsState, peerId: PeerId) =
  # called after peer has disconnected from node

  if state.peerExtensions.hasKey(peerId):
    state.peerExtensions.del(peerId)
  state.sentExtensions.excl(peerId)

proc handleRPC*(
    state: ExtensionsState, peerId: PeerId, ctrlExtensions: ControlExtensions
) =
  if state.peerExtensions.hasKey(peerId):
    # peer is sending control message again but this node has already received extensions.
    # this is protocol error, therfore nodes reports missbehaviour.
    state.onMissbehave(peerId)
  else:
    # peer is sending extensions control message for the first time
    state.peerExtensions[peerId] = ctrlExtensions.toPeerExtensions()

    # when node has sent it's extensions then extensions have negotiated
    if peerId in state.sentExtensions:
      state.onNegotiated(peerId)

  # onHandleRPC event is always called
  state.onHandleRPC(peerId)

proc makeControlExtensions*(state: ExtensionsState): ControlExtensions =
  return state.nodeExtensions
