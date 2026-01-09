# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/tables
import chronos, results
import ../../../[types, ffi_types, alloc]
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
  topicHandler: PubsubTopicHandler
  topicUserData: pointer
  topics: SharedSeq[cstring]
  data: SharedSeq[byte]
  hook: pointer
  timeout: Duration

proc createShared*(
    T: type PubSubRequest,
    op: PubSubMsgType,
    topic: cstring = "",
    topicHandler: PubsubTopicHandler = nil,
    topicUserData: pointer = nil,
    topics: ptr cstring = nil,
    topicsLen: csize_t = 0,
    data: ptr byte = nil,
    dataLen: csize_t = 0,
    hook: pointer = nil,
    timeout = InfiniteDuration,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].topic = topic.alloc()
  ret[].topics = allocSharedSeqFromCArray(topics, topicsLen.int)
  ret[].data = allocSharedSeqFromCArray(data, dataLen.int)
  ret[].topicHandler = topicHandler
  ret[].topicUserData = topicUserData
  ret[].hook = hook
  ret[].timeout = timeout
  ret

proc destroyShared(self: ptr PubSubRequest) =
  deallocShared(self[].topic)
  deallocSharedSeq(self[].topics)
  deallocSharedSeq(self[].data)
  deallocShared(self)

proc process*(
    self: ptr PubSubRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let gossipSub = libp2p[].gossipSub.valueOr:
    return err("gossipsub not initialized")

  case self.operation
  of SUBSCRIBE:
    let pubsubTopicHandler = self.topicHandler
    let topicUserData = self.topicUserData
    let tpair = (topic: $self.topic, handler: pubsubTopicHandler)
    if not libp2p[].topicHandlers.hasKey(tpair):
      let topicHandler = proc(topic: string, data: seq[byte]): Future[void] {.async.} =
        pubsubTopicHandler(
          topic.cstring,
          if data.len > 0:
            data[0].addr
          else:
            nil,
          data.len.csize_t,
          topicUserData,
        )
      libp2p[].topicHandlers[tpair] = (handler: topicHandler, userData: topicUserData)
      gossipSub.subscribe($self.topic, topicHandler)
  of UNSUBSCRIBE:
    let tpair = (topic: $self.topic, handler: self.topicHandler)
    if libp2p[].topicHandlers.hasKey(tpair):
      let topicHandler =
        try:
          libp2p[].topicHandlers[tpair].handler
        except KeyError:
          raiseAssert "checked with hasKey"
      libp2p[].topicHandlers.del(tpair)
      gossipSub.unsubscribe($self.topic, topicHandler)
  of PUBLISH:
    discard await gossipSub.publish($self.topic, self.data.toSeq())
  of ADD_VALIDATOR:
    # TODO:
    discard
  of REMOVE_VALIDATOR:
    # TODO:
    discard

  return ok("")
