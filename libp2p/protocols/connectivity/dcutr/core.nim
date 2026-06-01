# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils

import chronos
import stew/objects
import protobuf_serialization, protobuf_serialization/std/enums
import results

import
  ../../../multiaddress,
  ../../../dial,
  ../../../errors,
  ../../../stream/connection,
  ../../../protobuf/utils

export multiaddress

const DcutrCodec* = "/libp2p/dcutr"

# Implements https://github.com/libp2p/specs/blob/master/relay/DCUtR.md#rpc-messages

type
  MsgType* {.pure.} = enum
    Connect = 100
    Sync = 300

  DcutrMsg* {.proto2.} = object
    msgType* {.fieldNumber: 1, required, ext.}: MsgType
    addrs* {.fieldNumber: 2, ext.}: seq[MultiAddress]

  DcutrError* = object of LPError

Protobuf.serializerFor([DcutrMsg])

proc send*(
    stream: Stream, msgType: MsgType, addrs: seq[MultiAddress]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let pb = DcutrMsg(msgType: msgType, addrs: addrs).encode()
  await stream.writeLp(pb)

proc waitExpectedConnection*[T](
    fut: Future[T]
): Future[void] {.async: (raises: [DialFailedError, CancelledError]).} =
  discard await fut

proc getHolePunchableAddrs*(
    addrs: seq[MultiAddress]
): seq[MultiAddress] {.raises: [LPError].} =
  var res = newSeq[MultiAddress]()
  for a in addrs:
    # This is necessary to also accept addrs like /ip4/198.51.100/tcp/1234/p2p/QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N
    if [TCP, mapAnd(TCP_DNS, P2PPattern), mapAnd(TCP_IP, P2PPattern)].anyIt(it.match(a)):
      res.add(a[0 .. 1].tryGet())
    elif [
      QUIC_V1, mapAnd(QUIC_V1_DNS, P2PPattern), mapAnd(QUIC_V1_IP, P2PPattern)
    ].anyIt(it.match(a)):
      res.add(a[0 .. 2].tryGet())
  return res
