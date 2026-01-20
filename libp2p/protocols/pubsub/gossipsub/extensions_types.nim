import ../../../[peerid]

proc noopPeerCallback*(peer: PeerId) {.gcsafe, raises: [].} =
  discard

type PeerCallback* = proc(peer: PeerId) {.gcsafe, raises: [].}

type Extension* = ref object of RootObj

method onNegotiated*(ext: Extension, peerId: PeerId) {.base, gcsafe, raises: [].} =
  raiseAssert "must be implemented"

method onHandleRPC*(ext: Extension, peerId: PeerId) {.base, gcsafe, raises: [].} =
  raiseAssert "must be implemented"
