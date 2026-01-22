# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.push raises: [].}

import options, sequtils
import ../../../[peerid, routing_record, utility]

export options

proc expectedFields[T](
    t: typedesc[T], existingFieldNames: seq[string]
) {.raises: [CatchableError].} =
  var fieldNames: seq[string]
  for name, _ in fieldPairs(T()):
    fieldNames &= name
  if fieldNames != existingFieldNames:
    fieldNames.keepIf(
      proc(it: string): bool =
        it notin existingFieldNames
    )
    raise newException(
      CatchableError,
      $T &
        " fields changed, please search for and revise all relevant procs. New fields: " &
        $fieldNames,
    )

type
  PeerInfoMsg* = object
    peerId*: PeerId
    signedPeerRecord*: seq[byte]

  SubOpts* = object
    subscribe*: bool
    topic*: string
    # When true, it signals the receiver that the sender prefers partial messages.
    requestsPartial*: Option[bool]
    # When true, it signals the receiver that the sender supports sending partial
    # messages on this topic.
    # When requestsPartial is true, this is assumed to be true.
    supportsSendingPartial*: Option[bool]

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
    topic*: string
    signature*: seq[byte]
    key*: seq[byte]

  ControlExtensions* = object
    partialMessageExtension*: Option[bool]

    # Experimental extensions fields:
    testExtension*: Option[bool]

  ControlMessage* = object
    ihave*: seq[ControlIHave]
    iwant*: seq[ControlIWant]
    graft*: seq[ControlGraft]
    prune*: seq[ControlPrune]
    idontwant*: seq[ControlIWant]
    extensions*: Option[ControlExtensions]
    when defined(libp2p_gossipsub_1_4):
      preamble*: seq[ControlPreamble]
      imreceiving*: seq[ControlIMReceiving]

  ControlIHave* = object
    topicID*: string
    messageIDs*: seq[MessageId]

  ControlIWant* = object
    messageIDs*: seq[MessageId]

  ControlGraft* = object
    topicID*: string

  ControlPrune* = object
    topicID*: string
    peers*: seq[PeerInfoMsg]
    backoff*: uint64

  ControlPreamble* = object
    topicID*: string
    messageID*: MessageId
    messageLength*: uint32

  ControlIMReceiving* = object
    messageID*: MessageId
    messageLength*: uint32

  TestExtensionRPC* = object

  PartialMessageExtensionRPC* = object
    topicID*: string
    gorupID*: seq[byte]
    partialMessage*: seq[byte]
    partsMetadata*: seq[byte]

  RPCMsg* = object
    subscriptions*: seq[SubOpts]
    messages*: seq[Message]
    control*: Option[ControlMessage]
    partialMessageExtension*: Option[PartialMessageExtensionRPC]
    testExtension*: Option[TestExtensionRPC]
    # should be experimental extension in future
    ping*: seq[byte]
    pong*: seq[byte]

func withSubs*(T: type RPCMsg, topics: openArray[string], subscribe: bool): T =
  T(subscriptions: topics.mapIt(SubOpts(subscribe: subscribe, topic: it)))

func shortLog*(s: ControlIHave): auto =
  (topic: s.topicID.shortLog, messageIDs: mapIt(s.messageIDs, it.shortLog))

func shortLog*(s: ControlIWant): auto =
  (messageIDs: mapIt(s.messageIDs, it.shortLog))

func shortLog*(s: ControlGraft): auto =
  (topic: s.topicID.shortLog)

func shortLog*(s: ControlPrune): auto =
  (topic: s.topicID.shortLog)

func shortLog*(s: ControlPreamble): auto =
  (topic: s.topicID.shortLog, messageID: s.messageID.shortLog)

func shortLog*(s: ControlIMReceiving): auto =
  (messageID: s.messageID.shortLog)

func shortLogOpt[T](s: Option[T]): string =
  if s.isNone():
    "<unset>"
  else:
    $s.get()

func shortLog*(so: Option[ControlExtensions]): auto =
  if so.isNone():
    (
      partialMessageExtension: "<unset>", #
      testExtension: "<unset>",
    )
  else:
    let s = so.get()
    (
      partialMessageExtension: shortLogOpt(s.partialMessageExtension),
      testExtension: shortLogOpt(s.testExtension),
    )

func shortLog*(c: ControlMessage): auto =
  when defined(libp2p_gossipsub_1_4):
    (
      ihave: mapIt(c.ihave, it.shortLog),
      iwant: mapIt(c.iwant, it.shortLog),
      graft: mapIt(c.graft, it.shortLog),
      prune: mapIt(c.prune, it.shortLog),
      extensions: shortLog(c.extensions),
      preamble: mapIt(c.preamble, it.shortLog),
      imreceiving: mapIt(c.imreceiving, it.shortLog),
    )
  else:
    (
      ihave: mapIt(c.ihave, it.shortLog),
      iwant: mapIt(c.iwant, it.shortLog),
      graft: mapIt(c.graft, it.shortLog),
      prune: mapIt(c.prune, it.shortLog),
      extensions: shortLog(c.extensions),
    )

func shortLog*(msg: Message): auto =
  (
    fromPeer: msg.fromPeer.shortLog,
    data: msg.data.shortLog,
    seqno: msg.seqno.shortLog,
    topic: msg.topic,
    signature: msg.signature.shortLog,
    key: msg.key.shortLog,
  )

func shortLog*(pme: PartialMessageExtensionRPC): auto =
  (
    topicID: pme.topicID.shortLog,
    gorupID: pme.gorupID.shortLog,
    partialMessage: pme.partialMessage.shortLog,
    partsMetadata: pme.partsMetadata.shortLog,
  )

func shortLog*(m: RPCMsg): auto =
  (
    subscriptions: m.subscriptions,
    messages: mapIt(m.messages, it.shortLog),
    control: m.control.get(ControlMessage()).shortLog,
    partialMessageExtension:
      m.partialMessageExtension.get(PartialMessageExtensionRPC()).shortLog,
    testExtension: m.testExtension.shortLogOpt,
  )

static:
  expectedFields(PeerInfoMsg, @["peerId", "signedPeerRecord"])
proc byteSize(peerInfo: PeerInfoMsg): int =
  peerInfo.peerId.len + peerInfo.signedPeerRecord.len

proc byteSize(v: Option[bool]): int =
  if v.isSome(): 1 else: 0

static:
  expectedFields(
    SubOpts, @["subscribe", "topic", "requestsPartial", "supportsSendingPartial"]
  )
proc byteSize(subOpts: SubOpts): int =
  1 + # subscribe: 1 byte for the bool
  subOpts.topic.len + #
  subOpts.requestsPartial.byteSize() + #
  subOpts.supportsSendingPartial.byteSize()

static:
  expectedFields(Message, @["fromPeer", "data", "seqno", "topic", "signature", "key"])
proc byteSize*(msg: Message): int =
  msg.fromPeer.len + msg.data.len + msg.seqno.len + msg.signature.len + msg.key.len +
    msg.topic.len

proc byteSize*(msgs: seq[Message]): int =
  msgs.foldl(a + b.byteSize, 0)

static:
  expectedFields(ControlIHave, @["topicID", "messageIDs"])
proc byteSize(controlIHave: ControlIHave): int =
  controlIHave.topicID.len + controlIHave.messageIDs.foldl(a + b.len, 0)

proc byteSize*(ihaves: seq[ControlIHave]): int =
  ihaves.foldl(a + b.byteSize, 0)

static:
  expectedFields(ControlIWant, @["messageIDs"])
proc byteSize(controlIWant: ControlIWant): int =
  controlIWant.messageIDs.foldl(a + b.len, 0)

proc byteSize*(iwants: seq[ControlIWant]): int =
  iwants.foldl(a + b.byteSize, 0)

static:
  expectedFields(ControlGraft, @["topicID"])
proc byteSize(controlGraft: ControlGraft): int =
  controlGraft.topicID.len

static:
  expectedFields(ControlPrune, @["topicID", "peers", "backoff"])
proc byteSize(controlPrune: ControlPrune): int =
  controlPrune.topicID.len + controlPrune.peers.foldl(a + b.byteSize, 0) + 8
    # 8 bytes for uint64

static:
  expectedFields(ControlPreamble, @["topicID", "messageID", "messageLength"])
proc byteSize(controlPreamble: ControlPreamble): int =
  controlPreamble.topicID.len + controlPreamble.messageID.len + 4 # 4 bytes for uint32

proc byteSize*(preambles: seq[ControlPreamble]): int =
  preambles.foldl(a + b.byteSize, 0)

static:
  expectedFields(ControlIMReceiving, @["messageID", "messageLength"])
proc byteSize(controlIMreceiving: ControlIMReceiving): int =
  controlIMreceiving.messageID.len + 4 # 4 bytes for uint32

proc byteSize*(imreceivings: seq[ControlIMReceiving]): int =
  imreceivings.foldl(a + b.byteSize, 0)

static:
  expectedFields(ControlExtensions, @["partialMessageExtension", "testExtension"])
proc byteSize(controlExtensions: ControlExtensions): int =
  controlExtensions.partialMessageExtension.byteSize() + #
  controlExtensions.testExtension.byteSize()

proc byteSize(controlExtensions: Option[ControlExtensions]): int =
  controlExtensions.withValue(ce):
    ce.byteSize()
  else:
    0

static:
  expectedFields(TestExtensionRPC, @[])
proc byteSize(testExtensions: TestExtensionRPC): int =
  0 # type is empty

static:
  expectedFields(
    PartialMessageExtensionRPC,
    @["topicID", "gorupID", "partialMessage", "partsMetadata"],
  )
proc byteSize(pme: PartialMessageExtensionRPC): int =
  pme.topicID.len + #
  pme.gorupID.len + #
  pme.partialMessage.len + #
  pme.partsMetadata.len

when defined(libp2p_gossipsub_1_4):
  static:
    expectedFields(
      ControlMessage,
      @[
        "ihave", "iwant", "graft", "prune", "idontwant", "extensions", "preamble",
        "imreceiving",
      ],
    )
  proc byteSize(control: ControlMessage): int =
    control.ihave.foldl(a + b.byteSize, 0) + control.iwant.foldl(a + b.byteSize, 0) +
      control.graft.foldl(a + b.byteSize, 0) + control.prune.foldl(a + b.byteSize, 0) +
      control.idontwant.foldl(a + b.byteSize, 0) + byteSize(control.extensions) +
      control.preamble.foldl(a + b.byteSize, 0) +
      control.imreceiving.foldl(a + b.byteSize, 0)

else:
  static:
    expectedFields(
      ControlMessage, @["ihave", "iwant", "graft", "prune", "idontwant", "extensions"]
    )
  proc byteSize(control: ControlMessage): int =
    control.ihave.foldl(a + b.byteSize, 0) + control.iwant.foldl(a + b.byteSize, 0) +
      control.graft.foldl(a + b.byteSize, 0) + control.prune.foldl(a + b.byteSize, 0) +
      control.idontwant.foldl(a + b.byteSize, 0) + byteSize(control.extensions)

static:
  expectedFields(
    RPCMsg,
    @[
      "subscriptions", "messages", "control", "partialMessageExtension",
      "testExtension", "ping", "pong",
    ],
  )
proc byteSize*(rpc: RPCMsg): int =
  result =
    rpc.subscriptions.foldl(a + b.byteSize, 0) + byteSize(rpc.messages) + rpc.ping.len +
    rpc.pong.len
  rpc.control.withValue(ctrl):
    result += ctrl.byteSize
  rpc.partialMessageExtension.withValue(pme):
    result += pme.byteSize
  rpc.testExtension.withValue(te):
    result += te.byteSize
