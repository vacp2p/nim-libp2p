# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import options, sequtils, sugar
import "../../.."/[
        peerid,
        routing_record,
        utility
      ]

export options

proc expectedFields[T](t: typedesc[T], existingFieldNames: seq[string]) {.raises: [CatchableError].} =
  var fieldNames: seq[string]
  for name, _ in fieldPairs(T()):
    fieldNames &= name
  if fieldNames != existingFieldNames:
    fieldNames.keepIf(proc(it: string): bool = it notin existingFieldNames)
    raise newException(CatchableError, $T & " fields changed, please search for and revise all relevant procs. New fields: " & $fieldNames)

type
    PeerInfoMsg* = object
      peerId*: PeerId
      signedPeerRecord*: seq[byte]

    SubOpts* = object
      subscribe*: bool
      topic*: string

    MessageId* = seq[byte]

    SaltedId* = object
      # Salted hash of message ID - used instead of the ordinary message ID to
      # avoid hash poisoning attacks and to make memory usage more predictable
      # with respect to the variable-length message id
      data*: MDigest[256]

    Message* = object
      fromPeer*: PeerId
      data*: seq[byte]
      seqno*: seq[byte]
      topicIds*: seq[string]
      signature*: seq[byte]
      key*: seq[byte]

    ControlMessage* = object
      ihave*: seq[ControlIHave]
      iwant*: seq[ControlIWant]
      graft*: seq[ControlGraft]
      prune*: seq[ControlPrune]
      idontwant*: seq[ControlIWant]

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

static: expectedFields(PeerInfoMsg, @["peerId", "signedPeerRecord"])
proc byteSize(peerInfo: PeerInfoMsg): int =
  peerInfo.peerId.len + peerInfo.signedPeerRecord.len

static: expectedFields(SubOpts, @["subscribe", "topic"])
proc byteSize(subOpts: SubOpts): int =
  1 + subOpts.topic.len # 1 byte for the bool

static: expectedFields(Message, @["fromPeer", "data", "seqno", "topicIds", "signature", "key"])
proc byteSize*(msg: Message): int =
  msg.fromPeer.len + msg.data.len + msg.seqno.len +
         msg.signature.len + msg.key.len + msg.topicIds.foldl(a + b.len, 0)

proc byteSize*(msgs: seq[Message]): int =
  msgs.foldl(a + b.byteSize, 0)

static: expectedFields(ControlIHave, @["topicId", "messageIds"])
proc byteSize(controlIHave: ControlIHave): int =
  controlIHave.topicId.len + controlIHave.messageIds.foldl(a + b.len, 0)

proc byteSize*(ihaves: seq[ControlIHave]): int =
  ihaves.foldl(a + b.byteSize, 0)

static: expectedFields(ControlIWant, @["messageIds"])
proc byteSize(controlIWant: ControlIWant): int =
  controlIWant.messageIds.foldl(a + b.len, 0)

proc byteSize*(iwants: seq[ControlIWant]): int =
  iwants.foldl(a + b.byteSize, 0)

static: expectedFields(ControlGraft, @["topicId"])
proc byteSize(controlGraft: ControlGraft): int =
  controlGraft.topicId.len

static: expectedFields(ControlPrune, @["topicId", "peers", "backoff"])
proc byteSize(controlPrune: ControlPrune): int =
  controlPrune.topicId.len + controlPrune.peers.foldl(a + b.byteSize, 0) + 8 # 8 bytes for uint64

static: expectedFields(ControlMessage, @["ihave", "iwant", "graft", "prune", "idontwant"])
proc byteSize(control: ControlMessage): int =
  control.ihave.foldl(a + b.byteSize, 0) + control.iwant.foldl(a + b.byteSize, 0) +
  control.graft.foldl(a + b.byteSize, 0) + control.prune.foldl(a + b.byteSize, 0) +
  control.idontwant.foldl(a + b.byteSize, 0)

static: expectedFields(RPCMsg, @["subscriptions", "messages", "control", "ping", "pong"])
proc byteSize*(rpc: RPCMsg): int =
  result = rpc.subscriptions.foldl(a + b.byteSize, 0) + byteSize(rpc.messages) +
           rpc.ping.len + rpc.pong.len
  rpc.control.withValue(ctrl):
    result += ctrl.byteSize
