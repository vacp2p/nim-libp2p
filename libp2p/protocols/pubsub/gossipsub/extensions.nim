# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[options, sets, tables]
import ../../../[peerid]
import ../rpc/messages

proc noopPeerCallback(peer: PeerId) {.gcsafe, raises: [].} =
  discard

type
  PeerExtensions = object
    testExtensionSupported: bool

  PeerCallback* = proc(peer: PeerId) {.gcsafe, raises: [].}

  TestExtensionConfig* = object
    onNagotiated*: PeerCallback = noopPeerCallback
    onHandleRPC*: PeerCallback = noopPeerCallback

  ExtensionsState* = ref object
    sentExtensions: HashSet[PeerId] # nodes extensions were sent to peer
    peerExtensions: Table[PeerId, PeerExtensions] # received peer's extensions
    onMissbehave: PeerCallback

    # Extensions data & configuration:
    testExtensionConfig: Option[TestExtensionConfig]
      # when config is set then this node supports "test extension"

proc new*(
    T: typedesc[ExtensionsState],
    onMissbehave: PeerCallback = noopPeerCallback,
    testExtensionConfig: Option[TestExtensionConfig] = none(TestExtensionConfig),
): T =
  T(
    onMissbehave: onMissbehave,
    sentExtensions: initHashSet[PeerId](),
    testExtensionConfig: testExtensionConfig,
  )

proc toPeerExtensions(ctrlExtensions: ControlExtensions): PeerExtensions =
  let testExtensionSupported = ctrlExtensions.testExtension.valueOr:
    false
  PeerExtensions(testExtensionSupported: testExtensionSupported)

proc isExtensionNagotiatedTestExtensions(state: ExtensionsState, peerId: PeerId): bool =
  # does both this node peer support "test extension"?
  state.testExtensionConfig.isSome() and
    state.peerExtensions.getOrDefault(peerId).testExtensionSupported

proc onHandleRPC(state: ExtensionsState, peerId: PeerId) =
  # extensions event called when node receives every RPC message

  if state.isExtensionNagotiatedTestExtensions(peerId):
    state.testExtensionConfig.get().onHandleRPC(peerId)

proc onNagotiated(state: ExtensionsState, peerId: PeerId) =
  # extension event called when both sides have nagotiated (exchanged) extensions.
  # it will be called only once per connection session as soon as extensiosn are exchanged.

  if state.isExtensionNagotiatedTestExtensions(peerId):
    state.testExtensionConfig.get().onNagotiated(peerId)

proc addPeer*(state: ExtensionsState, peerId: PeerId) =
  # called after peer has connected to node and extensions control message is sent by gossipsub.

  state.sentExtensions.incl(peerId)

  # when node has received control extensions from peer then extensions have nagotiated
  if peerId in state.peerExtensions:
    state.onNagotiated(peerId)

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

    # when node has sent it's extensions then extensions have nagotiated
    if peerId in state.sentExtensions:
      state.onNagotiated(peerId)

  # onHandleRPC event is always called
  state.onHandleRPC(peerId)

proc makeControlExtensions*(state: ExtensionsState): ControlExtensions =
  # creates ControlExtensions message that is sent to other peers,
  # using configured state.

  ControlExtensions(testExtension: some(state.testExtensionConfig.isSome()))
