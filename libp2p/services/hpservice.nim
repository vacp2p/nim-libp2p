# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import ../switch
import chronos
import std/tables
import ../protocols/connectivity/autonat

type
  HPService* = ref object of Service
    newPeerHandler: PeerEventHandler
    networkReachability: NetworkReachability
    t: CountTable[NetworkReachability]
    maxConfidence: int

  NetworkReachability {.pure.} = enum
    Private, Public, Unknown

proc new*(T: typedesc[HPService], maxConfidence: int = 3): T =
  return T(
    newPeerHandler: nil,
    networkReachability: NetworkReachability.Unknown,
    maxConfidence: maxConfidence,
    t: initCountTable[NetworkReachability]())

proc handleAnswer(self: HPService, ans: NetworkReachability) =
  if ans == NetworkReachability.Unknown:
    return
  if ans == self.networkReachability:
    if self.t[ans] == self.maxConfidence:
      return
    self.t.inc(ans)
  else:
    if self.t[self.networkReachability] > 0:
      self.t.inc(self.networkReachability, -1)
    if self.t[ans] < self.maxConfidence:
      self.t.inc(ans)
    if self.t[ans] == self.maxConfidence or self.t[self.networkReachability] == 0:
      self.networkReachability = ans

proc askPeer(self: HPService, s: Switch, peerId: PeerId): Future[void] {.async.} =
  echo "Asking peer " & $(peerId)
  let ans =
    try:
      let ma = await Autonat.new(s).dialMe(peerId)
      NetworkReachability.Public
    except AutonatError:
      NetworkReachability.Private
  self.handleAnswer(ans)
  echo self.t
  echo self.networkReachability

proc h(self: HPService, switch: Switch) =
  for p in switch.peerStore[AddressBook].book.keys:
    discard askPeer(self, switch, p)

method setup*(self: HPService, switch: Switch) {.async.} =
  self.newPeerHandler = proc (peerId: PeerId, event: PeerEvent): Future[void] =
    return askPeer(self, switch, peerId)

  switch.connManager.addPeerEventHandler(self.newPeerHandler, PeerEventKind.Joined)

method run*(self: HPService, switch: Switch) {.async, gcsafe, public.} =
  h(self, switch)

method stop*(self: HPService, switch: Switch) {.async, gcsafe, public.} =
  if not isNil(self.newPeerHandler):
    switch.connManager.removePeerEventHandler(self.newPeerHandler, PeerEventKind.Joined)