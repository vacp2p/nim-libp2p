# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[json, sequtils]
import chronos, results
import ../../../[alloc, types]
import ../../../../libp2p

type PeerManagementMsgType* = enum
  CONNECT
  DISCONNECT
  PEER_INFO

type PeerManagementRequest* = object
  operation: PeerManagementMsgType
  peerId: cstring
  multiaddrs: SharedSeq[cstring]
  timeout: Duration

proc createShared*(
    T: type PeerManagementRequest,
    op: PeerManagementMsgType,
    peerId: cstring = "",
    multiaddrs: ptr cstring = nil,
    multiaddrsLen: csize_t = 0,
    timeout = InfiniteDuration, # not all ops need a timeout
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].multiaddrs = allocSharedSeqFromCArray(multiaddrs, multiaddrsLen.int)
  ret[].timeout = timeout
  return ret

proc destroyShared(self: ptr PeerManagementRequest) =
  deallocShared(self[].peerId)
  deallocSharedSeq(self[].multiaddrs)
  deallocShared(self)

proc process*(
    self: ptr PeerManagementRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  case self.operation
  of CONNECT:
    let multiaddresses =
      try:
        self.multiaddrs.toSeq().mapIt(MultiAddress.init($it).tryGet())
      except LPError:
        return err("invalid multiaddress")
    let peerId = PeerId.init($self[].peerId).valueOr:
      return err($error)
    try:
      await libp2p.switch.connect(peerId, multiaddresses).wait(self[].timeout)
    except AsyncTimeoutError:
      return err("dial timeout")
    except DialFailedError as exc:
      return err($exc.msg)
  of DISCONNECT:
    let peerId = PeerId.init($self[].peerId).valueOr:
      return err($error)
    await libp2p.switch.disconnect(peerId)
  of PEER_INFO:
    return ok(
      $ %*{
        "peerId": $libp2p.switch.peerInfo.peerId,
        "addrs": libp2p.switch.peerInfo.addrs.mapIt($it),
      }
    )

  return ok("")
