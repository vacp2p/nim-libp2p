# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[options, sets, tables]
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, extension_test, extension_partial_message, partial_message]

export TestExtensionConfig, PartialMessageExtensionConfig, TopicOpts

type OnMisbehaveProc* = proc(peer: PeerId) {.gcsafe, raises: [].}

proc noopMisbehave*(peer: PeerId) {.gcsafe, raises: [].} =
  discard

type ExtensionsState* = ref object
  sentExtensions: HashSet[PeerId] # tells to which peers has node sent ControlExtensions.
  peerExtensions: Table[PeerId, PeerExtensions]
    # tells what peer capabilities are (what extensions are supported by them).
  onMisbehave: OnMisbehaveProc
    # callback when peer does not follow extensions protocol. 
    # default implementation is set by GossipSub.createExtensionsState.
  nodeExtensions: ControlExtensions # tells what node's capabilities are.
  extensions: seq[Extension]
    # list of all extensions. state will delegate events to all elements of this list.
  partialMessageExtension: Option[PartialMessageExtension]
    # partialMessageExtension is needed to expose specific functionality of PartialMessageExtension 
    # via state.

proc new*(
    T: typedesc[ExtensionsState],
    onMisbehave: OnMisbehaveProc = noopMisbehave,
    testExtensionConfig: Option[TestExtensionConfig] = none(TestExtensionConfig),
    partialMessageExtensionConfig: Option[PartialMessageExtensionConfig] =
      none(PartialMessageExtensionConfig),
    externalExtensions: seq[Extension] = @[],
      # external extensions are created outside of state and they are added to 
      # state's extensions list.
): T =
  var state: T

  var nodeExtensions = ControlExtensions()
  var extensions = newSeq[Extension]()
  var partialMessageExtension: Option[PartialMessageExtension] =
    none(PartialMessageExtension)

  testExtensionConfig.withValue(c):
    extensions.add(TestExtension.new(c))
    nodeExtensions.testExtension = some(true)

  partialMessageExtensionConfig.withValue(c):
    var cfg = c # var is needed to set isSupported
    cfg.isSupported = proc(peerId: PeerId): bool {.gcsafe, raises: [].} =
      let peerExt = state.peerExtensions.getOrDefault(peerId)
      return state.partialMessageExtension.get().isSupported(peerExt)
    partialMessageExtension = some(PartialMessageExtension.new(cfg))
    extensions.add(partialMessageExtension.get())
    nodeExtensions.partialMessageExtension = some(true)

  extensions.add(externalExtensions)

  state = T(
    onMisbehave: onMisbehave,
    sentExtensions: initHashSet[PeerId](),
    nodeExtensions: nodeExtensions,
    extensions: extensions,
    partialMessageExtension: partialMessageExtension,
  )
  return state

proc toPeerExtensions(ce: ControlExtensions): PeerExtensions =
  let testExtension = ce.testExtension.valueOr:
    false
  let partialMessageExtension = ce.partialMessageExtension.valueOr:
    false

  PeerExtensions(
    testExtension: testExtension, #
    partialMessageExtension: partialMessageExtension,
  )

proc onHandleRPC(state: ExtensionsState, peerId: PeerId, rpc: RPCMsg) =
  # extension event called when node receives every RPC message.

  for _, e in state.extensions:
    e.onHandleRPC(peerId, rpc)

proc onNegotiated(state: ExtensionsState, peerId: PeerId) =
  # extension event called when both sides have negotiated (exchanged) extensions.
  # it will be called only once per connection session as soon as extensions are exchanged.

  for _, e in state.extensions:
    if e.isSupported(state.peerExtensions.getOrDefault(peerId)):
      e.onNegotiated(peerId)

proc onHeartbeat(state: ExtensionsState) =
  # extension event called on every gossipsub heartbeat.

  for _, e in state.extensions:
    e.onHeartbeat()

proc onRemovePeer(state: ExtensionsState, peerId: PeerId) =
  # extension event called when peer disconnects from gossipsub.

  for _, e in state.extensions:
    if e.isSupported(state.peerExtensions.getOrDefault(peerId)):
      e.onRemovePeer(peerId)

proc heartbeat*(state: ExtensionsState) =
  # triggers heartbeat event in extensions state.

  state.onHeartbeat()

proc addPeer*(state: ExtensionsState, peerId: PeerId) =
  # called after peer has connected to node and extensions control message is sent by gossipsub.

  state.sentExtensions.incl(peerId)

  # when node has received control extensions from peer then extensions have negotiated
  if peerId in state.peerExtensions:
    state.onNegotiated(peerId)

proc removePeer*(state: ExtensionsState, peerId: PeerId) =
  # called after peer has disconnected from node

  # first delegate event to all extensions
  state.onRemovePeer(peerId)

  # then remove all data from sate associated with peer
  if state.peerExtensions.hasKey(peerId):
    state.peerExtensions.del(peerId)
  state.sentExtensions.excl(peerId)

proc handleRPC*(state: ExtensionsState, peerId: PeerId, rpc: RPCMsg) =
  if rpc.control.isSome() and rpc.control.get().extensions.isSome():
    if state.peerExtensions.hasKey(peerId):
      # peer is sending control message again but this node has already received extensions.
      # this is protocol error, therfore nodes reports misbehavior.
      state.onMisbehave(peerId)
    else:
      # peer is sending extensions control message for the first time
      let ctrlExtensions = rpc.control.get().extensions.get()
      state.peerExtensions[peerId] = ctrlExtensions.toPeerExtensions()

      # when node has sent it's extensions then extensions have negotiated
      if peerId in state.sentExtensions:
        state.onNegotiated(peerId)

  # onHandleRPC event is always called
  state.onHandleRPC(peerId, rpc)

proc makeControlExtensions*(state: ExtensionsState): ControlExtensions =
  return state.nodeExtensions

proc publishPartial*(state: ExtensionsState, topic: string, pm: PartialMessage): int =
  state.partialMessageExtension.withValue(e):
    return e.publishPartial(topic, pm)
  else:
    # raises because this proc is called by user
    raiseAssert "partial message extension is not configured"

proc peerRequestsPartial*(state: ExtensionsState, peerId: PeerId, topic: string): bool =
  state.partialMessageExtension.withValue(e):
    return e.peerRequestsPartial(peerId, topic)
  else:
    # should not raise, because this is called whenever IDONTWANT is being sent.
    # so when extension is not configured it should return false, backwards compatible behavior.
    return false

