# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.push raises: [].}

import sequtils
import ../../../[peerid, routing_record, utility]

export results

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
    requestsPartial*: Opt[bool]
    # When true, it signals the receiver that the sender supports sending partial
    # messages on this topic.
    # When requestsPartial is true, this is assumed to be true.
    supportsSendingPartial*: Opt[bool]

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
    partialMessageExtension*: Opt[bool]

    # Experimental extensions fields:
    testExtension*: Opt[bool]
    pingpongExtension*: Opt[bool]
    preambleExtension*: Opt[bool]

  ControlMessage* = object
    ihave*: seq[ControlIHave]
    iwant*: seq[ControlIWant]
    graft*: seq[ControlGraft]
    prune*: seq[ControlPrune]
    idontwant*: seq[ControlIWant]
    extensions*: Opt[ControlExtensions]
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
    groupID*: seq[byte]
    partialMessage*: seq[byte]
    partsMetadata*: seq[byte]

  PingPongExtensionRPC* = object
    ping*: seq[byte]
    pong*: seq[byte]

  RPCMsg* = object
    subscriptions*: seq[SubOpts]
    messages*: seq[Message]
    control*: Opt[ControlMessage]
    partialMessageExtension*: Opt[PartialMessageExtensionRPC]
    testExtension*: Opt[TestExtensionRPC]
    pingpongExtension*: Opt[PingPongExtensionRPC]

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

func shortLogOpt[T](s: Opt[T]): string =
  if s.isNone():
    "<unset>"
  else:
    $s.get()

func shortLog*(so: Opt[ControlExtensions]): auto =
  if so.isNone():
    (
      partialMessageExtension: "<unset>",
      testExtension: "<unset>",
      pingpongExtension: "<unset>",
      preambleExtension: "<unset>",
    )
  else:
    let s = so.get()
    (
      partialMessageExtension: shortLogOpt(s.partialMessageExtension),
      testExtension: shortLogOpt(s.testExtension),
      pingpongExtension: shortLogOpt(s.pingpongExtension),
      preambleExtension: shortLogOpt(s.preambleExtension),
    )

func shortLog*(c: ControlMessage): auto =
  (
    ihave: mapIt(c.ihave, it.shortLog),
    iwant: mapIt(c.iwant, it.shortLog),
    graft: mapIt(c.graft, it.shortLog),
    prune: mapIt(c.prune, it.shortLog),
    extensions: shortLog(c.extensions),
    preamble: mapIt(c.preamble, it.shortLog),
    imreceiving: mapIt(c.imreceiving, it.shortLog),
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
    groupID: pme.groupID.shortLog,
    partialMessage: pme.partialMessage.shortLog,
    partsMetadata: pme.partsMetadata.shortLog,
  )

func shortLog*(m: RPCMsg): auto =
  (
    subscriptions: m.subscriptions,
    messages: mapIt(m.messages, it.shortLog),
    control: m.control.valueOr(ControlMessage()).shortLog,
    partialMessageExtension:
      m.partialMessageExtension.valueOr(PartialMessageExtensionRPC()).shortLog,
    testExtension: m.testExtension.shortLogOpt,
  )

static:
  expectedFields(PeerInfoMsg, @["peerId", "signedPeerRecord"])
proc byteSize(peerInfo: PeerInfoMsg): int =
  peerInfo.peerId.len + peerInfo.signedPeerRecord.len

proc byteSize(v: Opt[bool]): int =
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
  expectedFields(
    ControlExtensions,
    @[
      "partialMessageExtension", "testExtension", "pingpongExtension",
      "preambleExtension",
    ],
  )
proc byteSize(controlExtensions: ControlExtensions): int =
  controlExtensions.partialMessageExtension.byteSize() +
    controlExtensions.testExtension.byteSize() +
    controlExtensions.pingpongExtension.byteSize() +
    controlExtensions.preambleExtension.byteSize()

proc byteSize(rpc: PingPongExtensionRPC): int =
  rpc.ping.len + rpc.pong.len

proc byteSize(controlExtensions: Opt[ControlExtensions]): int =
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
    @["topicID", "groupID", "partialMessage", "partsMetadata"],
  )
proc byteSize(pme: PartialMessageExtensionRPC): int =
  pme.topicID.len + pme.groupID.len + pme.partialMessage.len + pme.partsMetadata.len

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

static:
  expectedFields(
    RPCMsg,
    @[
      "subscriptions", "messages", "control", "partialMessageExtension",
      "testExtension", "pingpongExtension",
    ],
  )
proc byteSize*(rpc: RPCMsg): int =
  result = rpc.subscriptions.foldl(a + b.byteSize, 0) + byteSize(rpc.messages)
  rpc.control.withValue(ctrl):
    result += ctrl.byteSize
  rpc.partialMessageExtension.withValue(pme):
    result += pme.byteSize
  rpc.testExtension.withValue(te):
    result += te.byteSize
  rpc.pingpongExtension.withValue(ppe):
    result += ppe.byteSize

# TODO reuse const
const preambleMessageSizeThreshold = 40 * 1024 # 40KiB

proc withPreamble*(
    _: typedesc[ControlMessage], msgs: seq[Message], msgIds: seq[MessageId]
): ControlMessage =
  var preambles: seq[ControlPreamble]
  for i, m in msgs:
    if m.data.len < preambleMessageSizeThreshold:
      preambles.add(
        ControlPreamble(
          topicID: m.topic, messageID: msgIds[i], messageLength: m.data.len.uint32
        )
      )
  ControlMessage(preamble: preambles)

proc withPreamble*(
    _: typedesc[ControlMessage], msg: Message, msgId: MessageId
): ControlMessage =
  ControlMessage.withPreamble(@[msg], @[msgId])

proc withImreceiving*(
    _: typedesc[ControlMessage], preamble: ControlPreamble
): ControlMessage =
  ControlMessage(
    imreceiving:
      @[
        ControlIMReceiving(
          messageID: preamble.messageID, messageLength: preamble.messageLength
        )
      ]
  )

proc withIWant*(_: typedesc[ControlMessage], msgId: MessageId): ControlMessage =
  ControlMessage(iwant: @[ControlIWant(messageIDs: @[msgId])])
