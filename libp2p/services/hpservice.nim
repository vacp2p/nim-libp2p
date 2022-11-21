when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import ../switch
import chronos
import std/tables

type
  HPService* = ref object of Service
    newPeerHandler: PeerEventHandler

proc askPeer(s: Switch, peerId: PeerId): Future[void] {.async.} =
  echo "Asking peer " & $(peerId)

proc h(switch: Switch) =
  for p in switch.peerStore[AddressBook].book.keys:
    discard askPeer(switch, p)

method setup*(self: HPService, switch: Switch) {.async.} =
  self.newPeerHandler = proc (peerId: PeerId, event: PeerEvent): Future[void] =
    return askPeer(switch, peerId)

  switch.connManager.addPeerEventHandler(self.newPeerHandler, PeerEventKind.Joined)

method run*(self: HPService, switch: Switch) {.async, gcsafe, public.} =
  h(switch)

method stop*(self: HPService, switch: Switch) {.async, gcsafe, public.} =
  if not isNil(self.newPeerHandler):
    switch.connManager.removePeerEventHandler(self.newPeerHandler, PeerEventKind.Joined)