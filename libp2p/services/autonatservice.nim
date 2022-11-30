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

import std/options
import ../switch
import chronos
import std/tables
import ../protocols/[connectivity/autonat,
                    rendezvous]
import ../discovery/[rendezvousinterface, discoverymngr]
import ../protocols/connectivity/relay/[relay, client]

type
  AutonatService* = ref object of Service
    newPeerHandler: PeerEventHandler
    networkReachability: NetworkReachability
    t: CountTable[NetworkReachability]
    autonat: Autonat
    newStatusHandler: NewStatusHandler
    maxConfidence: int


  NetworkReachability* {.pure.} = enum
    Private, Public, Unknown

  NewStatusHandler* = proc (networkReachability: NetworkReachability): Future[void]  {.gcsafe, raises: [Defect].}

proc new*(T: typedesc[AutonatService], autonat: Autonat, scheduleInterval: Option[Duration] = none(Duration), maxConfidence: int = 3): T =
  return T(
    newPeerHandler: nil,
    networkReachability: NetworkReachability.Unknown,
    maxConfidence: maxConfidence,
    autonat: autonat,
    scheduleInterval: scheduleInterval,
    t: initCountTable[NetworkReachability]())

proc networkReachability*(self: AutonatService): NetworkReachability {.inline.} =
  return self.networkReachability

proc handleAnswer(self: AutonatService, ans: NetworkReachability) {.async.} =
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

  if self.t[self.networkReachability] == self.maxConfidence:
    if not isNil(self.newStatusHandler):
      await self.newStatusHandler(self.networkReachability)

  trace "Current status confidence", confidence = $self.t
  trace "Current status", currentStats = $self.networkReachability

proc askPeer(self: AutonatService, s: Switch, peerId: PeerId): Future[void] {.async.} =
  trace "Asking for reachability", peerId = $peerId
  let ans =
    try:
      let ma = await self.autonat.dialMe(peerId)
      NetworkReachability.Public
    except AutonatError:
      NetworkReachability.Private
  await self.handleAnswer(ans)

proc h(self: AutonatService, switch: Switch) {.async.} =
  for p in switch.peerStore[AddressBook].book.keys:
    await askPeer(self, switch, p)

method setup*(self: AutonatService, switch: Switch) {.async.} =
  self.newPeerHandler = proc (peerId: PeerId, event: PeerEvent): Future[void] =
    return askPeer(self, switch, peerId)

  switch.connManager.addPeerEventHandler(self.newPeerHandler, PeerEventKind.Joined)

method run*(self: AutonatService, switch: Switch) {.async, public.} =
  await h(self, switch)

method stop*(self: AutonatService, switch: Switch) {.async, public.} =
  if not isNil(self.newPeerHandler):
    switch.connManager.removePeerEventHandler(self.newPeerHandler, PeerEventKind.Joined)

proc onNewStatuswithMaxConfidence*(self: AutonatService, f: NewStatusHandler) =
  self.newStatusHandler = f
