# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## `IdentifyPusher` — orchestrates the IdentifyPush protocol.
##
## Tracks which connected peers advertise the IdentifyPush codec, keeps that
## set in sync with connect / disconnect / re-identify events, and broadcasts
## our updated `PeerInfo` to every tracked peer when triggered.

{.push raises: [].}

import std/[sets, sequtils]
import chronos, chronicles
import
  ./protocols/identify,
  ./peerinfo,
  ./peerid,
  ./peerstore,
  ./connmanager,
  ./multistream,
  ./stream/connection,
  ./muxers/muxer,
  ./utils/future

export identify

logScope:
  topics = "libp2p identifypusher"

type
  PushSendFut = Future[void].Raising([CancelledError])

  IdentifyPusher* = ref object
    identifyPush*: IdentifyPush
    pushPeers*: HashSet[PeerId]
    ongoingSend*: seq[PushSendFut]
    connManager: ConnManager
    peerStore: PeerStore
    peerInfo: PeerInfo
    onIdentifiedHandler: PeerEventHandler
    onLeftHandler: PeerEventHandler
    onPeerInfoUpdated: PeerInfoObserver

proc new*(
    T: type IdentifyPusher,
    connManager: ConnManager,
    peerStore: PeerStore,
    peerInfo: PeerInfo,
): T =
  T(connManager: connManager, peerStore: peerStore, peerInfo: peerInfo)

proc sendOne(p: IdentifyPusher, peerId: PeerId) {.async: (raises: [CancelledError]).} =
  let muxer = p.connManager.selectMuxer(peerId)
  if muxer.isNil:
    return
  var stream: Connection
  try:
    stream = await muxer.newStream()
    if stream.isNil:
      trace "could not open new stream", peerId
      return

    if await MultistreamSelect.select(stream, IdentifyPushCodec):
      await p.identifyPush.push(p.peerInfo, stream)
  except CancelledError as e:
    raise e
  except MuxerError as e:
    trace "failed to open stream for identify push", peerId, description = e.msg
  except MultiStreamError as e:
    trace "multistream negotiation failed for identify push",
      peerId, description = e.msg
  except LPStreamError as e:
    trace "stream error during identify push", peerId, description = e.msg
  finally:
    if not stream.isNil:
      await stream.closeWithEOF()

proc broadcast*(p: IdentifyPusher) =
  ## Send an IdentifyPush message with our current `peerInfo` to every
  ## connected peer that advertises the IdentifyPush protocol.
  ## Each send runs as a background future; this proc returns immediately
  ## without blocking the caller.
  if p.identifyPush.isNil:
    return

  for peerId in p.pushPeers.toSeq():
    let fut = p.sendOne(peerId)
    p.ongoingSend.add(fut)
    fut.addCallback proc(udata: pointer) =
      let idx = p.ongoingSend.find(fut)
      if idx >= 0:
        p.ongoingSend.del(idx)

proc start*(p: IdentifyPusher) =
  ## Construct the IdentifyPush protocol and register the connection manager
  ## hooks that maintain `pushPeers`. The caller is responsible for mounting
  ## `p.identifyPush` on a Switch.

  proc onPeerInfoUpdated(peerInfo: PeerInfo) {.gcsafe, raises: [].} =
    p.broadcast()

  p.onPeerInfoUpdated = onPeerInfoUpdated
  p.peerInfo.addObserver(p.onPeerInfoUpdated)

  proc onIncomingPush(peerId: PeerId, info: IdentifyInfo) {.async.} =
    p.peerStore.updatePeerInfo(info)
    if IdentifyPushCodec in info.protos:
      p.pushPeers.incl(peerId)
    else:
      p.pushPeers.excl(peerId)

  p.identifyPush = IdentifyPush.new(onIncomingPush)

  proc onIdentified(
      peerId: PeerId, event: PeerEvent
  ) {.async: (raises: [CancelledError]).} =
    if IdentifyPushCodec in p.peerStore[ProtoBook][peerId]:
      p.pushPeers.incl(peerId)
    else:
      p.pushPeers.excl(peerId)

  proc onLeft(peerId: PeerId, event: PeerEvent) {.async: (raises: [CancelledError]).} =
    p.pushPeers.excl(peerId)

  p.onIdentifiedHandler = onIdentified
  p.onLeftHandler = onLeft
  p.connManager.addPeerEventHandler(onIdentified, PeerEventKind.Identified)
  p.connManager.addPeerEventHandler(onLeft, PeerEventKind.Left)

proc stop*(p: IdentifyPusher) {.async: (raises: []).} =
  ## Cancel any in-flight pushes and unregister connection manager hooks.
  if not p.onIdentifiedHandler.isNil:
    p.connManager.removePeerEventHandler(
      p.onIdentifiedHandler, PeerEventKind.Identified
    )
    p.onIdentifiedHandler = nil
  if not p.onLeftHandler.isNil:
    p.connManager.removePeerEventHandler(p.onLeftHandler, PeerEventKind.Left)
    p.onLeftHandler = nil
  if not p.onPeerInfoUpdated.isNil:
    p.peerInfo.removeObserver(p.onPeerInfoUpdated)

  let pending = move(p.ongoingSend)
  pending.cancelSoon()

  p.pushPeers.clear()
  p.identifyPush = nil
