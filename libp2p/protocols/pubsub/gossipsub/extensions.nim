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

type
  PeerExtensions = object
    testExtension: bool

  PeerCallback* = proc(peer: PeerId) {.gcsafe, raises: [].}

  TestExtensionConfig* = object
    onNagotiated: PeerCallback
    onHandleRPC: PeerCallback

  ExtensionsState* = ref object
    sentExtensions: HashSet[PeerId] # extensions was sent to peer
    peerExtensions: Table[PeerId, PeerExtensions] # supported peer extensions
    onMissbehave: PeerCallback

    # Extensions data & configuration:
    testExtensionConfig: Option[TestExtensionConfig]
      # when config is set then this node supports "text extension"

proc noopPeerCallback(peer: PeerId) {.gcsafe, raises: [].} =
  discard

proc new*(
    T: typedesc[TestExtensionConfig],
    onNagotiated: PeerCallback = noopPeerCallback,
    onHandleRPC: PeerCallback = noopPeerCallback,
): T =
  T(onNagotiated: onNagotiated, onHandleRPC: onHandleRPC)

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
  let testExtension = ctrlExtensions.testExtension.valueOr:
    false
  PeerExtensions(testExtension: testExtension)

proc isExtensionNagotiatedTestExtensions(state: ExtensionsState, peerId: PeerId): bool =
  # this node supports "test extension" and peers supports it 
  state.testExtensionConfig.isSome() and
    state.peerExtensions.getOrDefault(peerId).testExtension

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
  state.sentExtensions.incl(peerId)

  if peerId in state.peerExtensions:
    state.onNagotiated(peerId)

proc removePeer*(state: ExtensionsState, peerId: PeerId) =
  if state.peerExtensions.hasKey(peerId):
    state.peerExtensions.del(peerId)
  state.sentExtensions.excl(peerId)

proc handleRPC*(
    state: ExtensionsState, peerId: PeerId, ctrlExtensions: ControlExtensions
) =
  if state.peerExtensions.hasKey(peerId):
    # peer is sending control message again but this node has already received extensions.
    # this is protocol error, therfore nodes reports missbehaioir.
    state.onMissbehave(peerId)
  else:
    # peer is sending extensions control message for the first time
    state.peerExtensions[peerId] = ctrlExtensions.toPeerExtensions()

    # and if node sent it's extensions then extensions have nagotiated
    if peerId in state.sentExtensions:
      state.onNagotiated(peerId)

  # onHandleRPC event is always called
  state.onHandleRPC(peerId)
