# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[options, sets, tables]
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, extension_test, extension_partial_message]

export PeerCallback, TestExtensionConfig, PartialMessageExtensionConfig

type
  PeerExtensions = object
    testExtensionSupported: bool
    partialMessageExtensionSupported: bool

  ExtensionsState* = ref object
    sentExtensions: HashSet[PeerId] # nodes extensions were sent to peer
    peerExtensions: Table[PeerId, PeerExtensions] # received peer's extensions
    onMissbehave: PeerCallback

    # All extensions logic
    testExtension: Option[Extension]
    partialMessageExtension: Option[Extension]

proc new*(
    T: typedesc[ExtensionsState],
    onMissbehave: PeerCallback = noopPeerCallback,
    testExtensionConfig: Option[TestExtensionConfig] = none(TestExtensionConfig),
    partialMessageExtensionConfig: Option[PartialMessageExtensionConfig] =
      none(PartialMessageExtensionConfig),
): T =
  T(
    onMissbehave: onMissbehave,
    sentExtensions: initHashSet[PeerId](),
    testExtension: TestExtension.new(testExtensionConfig),
    partialMessageExtension: PartialMessageExtension.new(partialMessageExtensionConfig),
  )

proc toPeerExtensions(ce: ControlExtensions): PeerExtensions =
  let testExtensionSupported = ce.testExtension.valueOr:
    false
  let partialMessageExtensionSupported = ce.partialMessageExtension.valueOr:
    false

  PeerExtensions(
    testExtensionSupported: testExtensionSupported,
    partialMessageExtensionSupported: partialMessageExtensionSupported,
  )

proc isNegotiated_TestExtension(state: ExtensionsState, peerId: PeerId): bool =
  # does both this node peer support "test extension"?
  state.testExtension.isSome() and
    state.peerExtensions.getOrDefault(peerId).testExtensionSupported

proc isNegotiated_PartialMessageExtension(
    state: ExtensionsState, peerId: PeerId
): bool =
  # does both this node peer support "partial message extension"?
  state.partialMessageExtension.isSome() and
    state.peerExtensions.getOrDefault(peerId).partialMessageExtensionSupported

proc onHandleRPC(state: ExtensionsState, peerId: PeerId) =
  # extensions event called when node receives every RPC message

  if state.isNegotiated_TestExtension(peerId):
    state.testExtension.get().onHandleRPC(peerId)

  if state.isNegotiated_PartialMessageExtension(peerId):
    state.partialMessageExtension.get().onHandleRPC(peerId)

proc onNegotiated(state: ExtensionsState, peerId: PeerId) =
  # extension event called when both sides have negotiated (exchanged) extensions.
  # it will be called only once per connection session as soon as extensiosn are exchanged.

  if state.isNegotiated_TestExtension(peerId):
    state.testExtension.get().onNegotiated(peerId)

  if state.isNegotiated_PartialMessageExtension(peerId):
    state.partialMessageExtension.get().onNegotiated(peerId)

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
  # creates ControlExtensions message that is sent to other peers,
  # using configured state.

  ControlExtensions(
    testExtension: some(state.testExtension.isSome()),
    partialMessageExtension: some(state.partialMessageExtension.isSome()),
  )
