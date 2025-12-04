# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, results

import ../../../[types, alloc]
import ../../../../libp2p/protocols/pubsub/gossipsub

type PubSubMsgType* = enum
  SUBSCRIBE
  UNSUBSCRIBE
  PUBLISH
  ADD_VALIDATOR
  REMOVE_VALIDATOR

type PubSubRequest* = object
  operation: PubSubMsgType
  topic: cstring
  topicHandler: pointer
  topics: SharedSeq[cstring]
  hook: pointer
  timeout: Duration

proc createShared*(
    T: type PubSubRequest,
    op: PubSubMsgType,
    topic: cstring = "",
    topicHandler: pointer = nil,
    topics: ptr cstring = nil,
    topicsLen: csize_t,
    hook: pointer = nil,
    timeout = InfiniteDuration,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].topic = topic.alloc()
  ret[].topics = allocSharedSeqFromCArray(topics, topicsLen.int)
  ret[].topicHandler = topicHandler
  ret[].hook = hook
  ret[].timeout = timeout

proc destroyShared(self: ptr PubSubRequest) =
  deallocShared(self[].topic)
  deallocSharedSeq(self[].topics)
  deallocShared(self)

proc process*(
    self: ptr PubSubRequest, libp2p: ptr LibP2P
): Future[Result[Opt[string], string]] {.async.} =
  defer:
    destroyShared(self)

  # TODO:
  case self.operation
  of SUBSCRIBE: discard
  of UNSUBSCRIBE: discard
  of PUBLISH: discard
  of ADD_VALIDATOR: discard
  of REMOVE_VALIDATOR: discard

  return ok(Opt.none(string))
