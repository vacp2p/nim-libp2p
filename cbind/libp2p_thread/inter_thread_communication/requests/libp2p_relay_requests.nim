# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sequtils
import chronos, results
import ../../../[alloc, ffi_types, types]
import ../../../../libp2p
import ../../../../libp2p/protocols/connectivity/relay/client

type RelayMsgType* = enum
  RELAY_RESERVE

type RelayRequest* = object
  operation*: RelayMsgType
  peerId: cstring
  multiaddrs: SharedSeq[cstring]

proc createShared*(
    T: type RelayRequest,
    op: RelayMsgType,
    peerId: cstring = "",
    multiaddrs: ptr cstring = nil,
    multiaddrsLen: csize_t = 0,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].multiaddrs = allocSharedSeqFromCArray(multiaddrs, multiaddrsLen.int)
  ret

proc destroyShared(self: ptr RelayRequest) =
  deallocShared(self[].peerId)
  deallocSharedSeq(self[].multiaddrs)
  deallocShared(self)

proc deallocReservationResult*(res: ptr ReservationResult) =
  if res.isNil():
    return
  deallocCStringArray(res[].addrs, res[].addrsLen)
  deallocShared(res)

proc allocReservationResult(addrs: seq[string], expire: uint64): ptr ReservationResult =
  let res = cast[ptr ReservationResult](createShared(ReservationResult, 1))
  res[].expireTime = expire
  res[].addrsLen = addrs.len.csize_t
  res[].addrs = allocCStringArrayFromSeq(addrs)
  res

proc processReserve*(
    self: ptr RelayRequest, libp2p: ptr LibP2P
): Future[Result[ptr ReservationResult, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let cl = libp2p[].relayClient.valueOr:
    return err("relay client is not mounted (set circuit_relay_client=1 in config)")

  let peerId = PeerId.init($self[].peerId).valueOr:
    return err($error)

  let multiaddresses =
    try:
      self[].multiaddrs.toSeq().mapIt(MultiAddress.init($it).tryGet())
    except LPError:
      return err("invalid multiaddress")

  let rsvp =
    try:
      await cl.reserve(peerId, multiaddresses)
    except ReservationError as exc:
      return err("reservation failed: " & exc.msg)
    except DialFailedError as exc:
      return err("dial failed: " & exc.msg)

  return ok(allocReservationResult(rsvp.addrs.mapIt($it), rsvp.expire))
