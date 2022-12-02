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
import ../utils/heartbeat
import ../crypto/crypto

type
  AutonatService* = ref object of Service
    registerLoop: Future[void]
    scheduleInterval: Option[Duration]
    networkReachability: NetworkReachability
    t: CountTable[NetworkReachability]
    autonat: Autonat
    newStatusHandler: NewStatusHandler
    rng: ref HmacDrbgContext
    numPeersToAsk: int
    maxConfidence: int


  NetworkReachability* {.pure.} = enum
    NotReachable, Reachable, Unknown

  NewStatusHandler* = proc (networkReachability: NetworkReachability): Future[void]  {.gcsafe, raises: [Defect].}

proc new*(
  T: typedesc[AutonatService],
  autonat: Autonat,
  rng: ref HmacDrbgContext,
  scheduleInterval: Option[Duration] = none(Duration),
  numPeersToAsk: int = 5,
  maxConfidence: int = 3): T =
  return T(
    scheduleInterval: scheduleInterval,
    networkReachability: NetworkReachability.Unknown,
    t: initCountTable[NetworkReachability](),
    autonat: autonat,
    rng: rng,
    numPeersToAsk: numPeersToAsk,
    maxConfidence: maxConfidence)

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
      NetworkReachability.Reachable
    except AutonatError:
      NetworkReachability.NotReachable
  await self.handleAnswer(ans)

proc askPeersInAddressBook(self: AutonatService, switch: Switch) {.async.} =
  var peers = switch.connectedPeers()
  self.rng.shuffle(peers)
  for idx in 0..<min(self.numPeersToAsk, peers.len):
    await askPeer(self, switch, peers[idx])

proc register(service: AutonatService, switch: Switch, interval: Duration) {.async.} =
  heartbeat "Register AutonatService run", interval:
    await service.run(switch)

method setup*(self: AutonatService, switch: Switch) {.async.} =
  if self.scheduleInterval.isSome:
      self.registerLoop = register(self, switch, self.scheduleInterval.get())

method run*(self: AutonatService, switch: Switch) {.async, public.} =
  await askPeersInAddressBook(self, switch)

method stop*(self: AutonatService, switch: Switch) {.async, public.} =
  if self.scheduleInterval.isSome and self.registerLoop != nil:
    self.registerLoop.cancel()
    self.registerLoop = nil

proc onNewStatuswithMaxConfidence*(self: AutonatService, f: NewStatusHandler) =
  self.newStatusHandler = f
