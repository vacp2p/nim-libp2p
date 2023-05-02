# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
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

import options, sequtils
import "../../.."/[
        peerid,
        routing_record,
        utility
      ]

export options

type
    PeerInfoMsg* = object
      peerId*: PeerId
      signedPeerRecord*: seq[byte]

    SubOpts* = object
      subscribe*: bool
      topic*: string

    MessageId* = seq[byte]

    Message* = object
      fromPeer*: PeerId
      data*: seq[byte]
      seqno*: seq[byte]
      topicIds*: seq[string]
      signature*: seq[byte]
      key*: seq[byte]

    ControlMessage* = object
      ihave*: seq[ControlIHave]
      dontSend*: seq[ControlIHave]
      sending*: seq[ControlIHave]
      iwant*: seq[ControlIWant]
      graft*: seq[ControlGraft]
      prune*: seq[ControlPrune]
      ping*: seq[byte]
      pong*: seq[byte]

    ControlIHave* = object
      topicId*: string
      messageIds*: seq[MessageId]

    ControlIWant* = object
      messageIds*: seq[MessageId]

    ControlGraft* = object
      topicId*: string

    ControlPrune* = object
      topicId*: string
      peers*: seq[PeerInfoMsg]
      backoff*: uint64

    RPCMsg* = object
      subscriptions*: seq[SubOpts]
      messages*: seq[Message]
      control*: Option[ControlMessage]

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
  if m.control.isSome:
    (
      subscriptions: m.subscriptions,
      messages: mapIt(m.messages, it.shortLog),
      control: m.control.get().shortLog
    )
  else:
    (
      subscriptions: m.subscriptions,
      messages: mapIt(m.messages, it.shortLog),
      control: ControlMessage().shortLog
    )
