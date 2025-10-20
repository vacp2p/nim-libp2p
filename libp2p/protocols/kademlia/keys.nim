import ../../peerid
import ../../switch
import ./protobuf
import chronicles
import results
import sugar

type Key* = seq[byte]

proc toKey*(p: PeerId): Key =
  return Key(p.data)

proc toPeerId*(k: Key): Result[PeerId, string] =
  PeerId.init(k).mapErr(x => $x)

proc toPeer*(k: Key, switch: Switch): Result[Peer, string] =
  let peer = ?k.toPeerId()
  let addrs = switch.peerStore[AddressBook][peer]
  if addrs.len == 0:
    return err("Could not find peer addresses in address book")

  ok(
    Peer(
      id: peer.getBytes(),
      addrs: addrs,
      connection:
        # TODO: this should likely be optional as it can reveal the network graph of a node
        if switch.isConnected(peer):
          ConnectionType.connected
        else:
          ConnectionType.notConnected,
    )
  )

proc shortLog*(k: Key): string =
  "key:" & toHex(k)

chronicles.formatIt(Key):
  shortLog(it)
