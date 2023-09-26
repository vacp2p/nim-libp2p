# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import options, sequtils
import "../../.."/[
        peerid,
        routing_record,
        utility
      ]

export options

type
    ## WARNING: After Modifying this type make sure to search for and revise all relevant procs.
    PeerInfoMsg* = object
      peerId*: PeerId
      signedPeerRecord*: seq[byte]

    ## WARNING: After Modifying this type make sure to search for and revise all relevant procs.
    SubOpts* = object
      subscribe*: bool
      topic*: string

    MessageId* = seq[byte]

    ## WARNING: After Modifying this type make sure to search for and revise all relevant procs.
    Message* = object
      fromPeer*: PeerId
      data*: seq[byte]
      seqno*: seq[byte]
      topicIds*: seq[string]
      signature*: seq[byte]
      key*: seq[byte]

    ## WARNING: After Modifying this type make sure to search for and revise all relevant procs.
    ControlMessage* = object
      ihave*: seq[ControlIHave]
      iwant*: seq[ControlIWant]
      graft*: seq[ControlGraft]
      prune*: seq[ControlPrune]
      idontwant*: seq[ControlIWant]

    ## WARNING: After Modifying this type make sure to search for and revise all relevant procs.
    ControlIHave* = object
      topicId*: string
      messageIds*: seq[MessageId]

    ## WARNING: After Modifying this type make sure to search for and revise all relevant procs.
    ControlIWant* = object
      messageIds*: seq[MessageId]

    ## WARNING: After Modifying this type make sure to search for and revise all relevant procs.
    ControlGraft* = object
      topicId*: string

    ## WARNING: After Modifying this type make sure to search for and revise all relevant procs.
    ControlPrune* = object
      topicId*: string
      peers*: seq[PeerInfoMsg]
      backoff*: uint64

    ## WARNING: After Modifying this type make sure to search for and revise all relevant procs.
    RPCMsg* = object
      subscriptions*: seq[SubOpts]
      messages*: seq[Message]
      control*: Option[ControlMessage]
      ping*: seq[byte]
      pong*: seq[byte]

func withSubs*(
    T: type RPCMsg, topics: openArray[string], subscribe: bool): T =
  T(
    subscriptions: topics.mapIt(SubOpts(subscribe: subscribe, topic: it)))

func shortLog*(s: ControlIHave): auto =
  (
    topicId: s.topicId.shortLog,
    messageIds: mapIt(s.messageIds, it.shortLog)
  )

func shortLog*(s: ControlIWant): auto =
  (
    messageIds: mapIt(s.messageIds, it.shortLog)
  )

func shortLog*(s: ControlGraft): auto =
  (
    topicId: s.topicId.shortLog
  )

func shortLog*(s: ControlPrune): auto =
  (
    topicId: s.topicId.shortLog
  )

func shortLog*(c: ControlMessage): auto =
  (
    ihave: mapIt(c.ihave, it.shortLog),
    iwant: mapIt(c.iwant, it.shortLog),
    graft: mapIt(c.graft, it.shortLog),
    prune: mapIt(c.prune, it.shortLog)
  )

func shortLog*(msg: Message): auto =
  (
    fromPeer: msg.fromPeer.shortLog,
    data: msg.data.shortLog,
    seqno: msg.seqno.shortLog,
    topicIds: $msg.topicIds,
    signature: msg.signature.shortLog,
    key: msg.key.shortLog
  )

func shortLog*(m: RPCMsg): auto =
  (
    subscriptions: m.subscriptions,
    messages: mapIt(m.messages, it.shortLog),
    control: m.control.get(ControlMessage()).shortLog
  )

proc len(peerInfo: PeerInfoMsg): int =
  peerInfo.peerId.len + peerInfo.signedPeerRecord.len

proc len(subOpts: SubOpts): int =
  1 + subOpts.topic.len # 1 byte for the bool

proc len*(msg: Message): int =
  msg.fromPeer.len + msg.data.len + msg.seqno.len +
         msg.signature.len + msg.key.len + msg.topicIds.foldl(a + b.len, 0)

proc len(controlIHave: ControlIHave): int =
  controlIHave.topicId.len + controlIHave.messageIds.foldl(a + b.len, 0)

proc len(controlIWant: ControlIWant): int =
  controlIWant.messageIds.foldl(a + b.len, 0)

proc len(controlGraft: ControlGraft): int =
  controlGraft.topicId.len

proc len(controlPrune: ControlPrune): int =
  controlPrune.topicId.len + controlPrune.peers.foldl(a + b.len, 0) + 8 # 8 bytes for uint64

proc len(control: ControlMessage): int =
  control.ihave.foldl(a + b.len, 0) + control.iwant.foldl(a + b.len, 0) +
  control.graft.foldl(a + b.len, 0) + control.prune.foldl(a + b.len, 0) +
  control.idontwant.foldl(a + b.len, 0)

proc len*(rpc: RPCMsg): int =
  result = rpc.subscriptions.foldl(a + b.len, 0) + rpc.messages.foldl(a + b.len, 0) +
           rpc.ping.len + rpc.pong.len
  rpc.control.withValue(ctrl):
    result += ctrl.len
