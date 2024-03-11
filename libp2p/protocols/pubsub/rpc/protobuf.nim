# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import options
import stew/assign2
import chronicles
import messages,
       ../../../peerid,
       ../../../utility,
       ../../../protobuf/minprotobuf


logScope:
  topics = "libp2p pubsubprotobuf"

when defined(libp2p_protobuf_metrics):
  import metrics

  declareCounter(libp2p_pubsub_rpc_bytes_read, "pubsub rpc bytes read", labels = ["kind"])
  declareCounter(libp2p_pubsub_rpc_bytes_write, "pubsub rpc bytes write", labels = ["kind"])

proc write*(pb: var ProtoBuffer, field: int, graft: ControlGraft) =
  var ipb = initProtoBuffer()
  ipb.write(1, graft.topicID)
  ipb.finish()
  pb.write(field, ipb)

  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_write.inc(ipb.getLen().int64, labelValues = ["graft"])

proc write*(pb: var ProtoBuffer, field: int, infoMsg: PeerInfoMsg) =
  var ipb = initProtoBuffer()
  ipb.write(1, infoMsg.peerId)
  ipb.write(2, infoMsg.signedPeerRecord)
  ipb.finish()
  pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, prune: ControlPrune) =
  var ipb = initProtoBuffer()
  ipb.write(1, prune.topicID)
  for peer in prune.peers:
    ipb.write(2, peer)
  ipb.write(3, prune.backoff)
  ipb.finish()
  pb.write(field, ipb)

  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_write.inc(ipb.getLen().int64, labelValues = ["prune"])

proc write*(pb: var ProtoBuffer, field: int, ihave: ControlIHave) =
  var ipb = initProtoBuffer()
  ipb.write(1, ihave.topicID)
  for mid in ihave.messageIDs:
    ipb.write(2, mid)
  ipb.finish()
  pb.write(field, ipb)

  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_write.inc(ipb.getLen().int64, labelValues = ["ihave"])

proc write*(pb: var ProtoBuffer, field: int, iwant: ControlIWant) =
  var ipb = initProtoBuffer()
  for mid in iwant.messageIDs:
    ipb.write(1, mid)
  if len(ipb.buffer) > 0:
    ipb.finish()
    pb.write(field, ipb)

  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_write.inc(ipb.getLen().int64, labelValues = ["iwant"])

proc write*(pb: var ProtoBuffer, field: int, control: ControlMessage) =
  var ipb = initProtoBuffer()
  for ihave in control.ihave:
    ipb.write(1, ihave)
  for iwant in control.iwant:
    ipb.write(2, iwant)
  for graft in control.graft:
    ipb.write(3, graft)
  for prune in control.prune:
    ipb.write(4, prune)
  for idontwant in control.idontwant:
    ipb.write(5, idontwant)
  if len(ipb.buffer) > 0:
    ipb.finish()
    pb.write(field, ipb)

proc write*(pb: var ProtoBuffer, field: int, subs: SubOpts) =
  var ipb = initProtoBuffer()
  ipb.write(1, uint64(subs.subscribe))
  ipb.write(2, subs.topic)
  ipb.finish()
  pb.write(field, ipb)

  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_write.inc(ipb.getLen().int64, labelValues = ["subs"])

proc encodeMessage*(msg: Message, anonymize: bool): seq[byte] =
  var pb = initProtoBuffer()
  if len(msg.fromPeer) > 0 and not anonymize:
    pb.write(1, msg.fromPeer)
  pb.write(2, msg.data)
  if len(msg.seqno) > 0 and not anonymize:
    pb.write(3, msg.seqno)
  pb.write(4, msg.topic)
  if len(msg.signature) > 0 and not anonymize:
    pb.write(5, msg.signature)
  if len(msg.key) > 0 and not anonymize:
    pb.write(6, msg.key)
  pb.finish()

  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_write.inc(pb.getLen().int64, labelValues = ["message"])

  pb.buffer

proc write*(pb: var ProtoBuffer, field: int, msg: Message, anonymize: bool) =
  pb.write(field, encodeMessage(msg, anonymize))

proc decodeGraft*(pb: ProtoBuffer): ProtoResult[ControlGraft] {.
     inline.} =
  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_read.inc(pb.getLen().int64, labelValues = ["graft"])

  trace "decodeGraft: decoding message"
  var control = ControlGraft()
  if ? pb.getField(1, control.topicID):
    trace "decodeGraft: read topicID", topicID = control.topicID
  else:
    trace "decodeGraft: topicID is missing"
  ok(control)

proc decodePeerInfoMsg*(pb: ProtoBuffer): ProtoResult[PeerInfoMsg] {.
     inline.} =
  trace "decodePeerInfoMsg: decoding message"
  var pi = PeerInfoMsg()
  if ? pb.getField(1, pi.peerId):
    trace "decodePeerInfoMsg: read peerId", peerId = pi.peerId
  else:
    trace "decodePeerInfoMsg: peerId is missing"
  if ? pb.getField(2, pi.signedPeerRecord):
    trace "decodePeerInfoMsg: read signedPeerRecord", signedPeerRecord = pi.signedPeerRecord
  else:
    trace "decodePeerInfoMsg: signedPeerRecord is missing"
  ok(pi)

proc decodePrune*(pb: ProtoBuffer): ProtoResult[ControlPrune] {.
     inline.} =
  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_read.inc(pb.getLen().int64, labelValues = ["prune"])

  trace "decodePrune: decoding message"
  var control = ControlPrune()
  if ? pb.getField(1, control.topicID):
    trace "decodePrune: read topicID", topic = control.topicID
  else:
    trace "decodePrune: topicID is missing"
  var bpeers: seq[seq[byte]]
  if ? pb.getRepeatedField(2, bpeers):
    for bpeer in bpeers:
      control.peers &= ? decodePeerInfoMsg(initProtoBuffer(bpeer))
  if ? pb.getField(3, control.backoff):
    trace "decodePrune: read backoff", backoff = control.backoff
  ok(control)

proc decodeIHave*(pb: ProtoBuffer): ProtoResult[ControlIHave] {.
     inline.} =
  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_read.inc(pb.getLen().int64, labelValues = ["ihave"])

  trace "decodeIHave: decoding message"
  var control = ControlIHave()
  if ? pb.getField(1, control.topicID):
    trace "decodeIHave: read topicID", topic = control.topicID
  else:
    trace "decodeIHave: topicID is missing"
  if ? pb.getRepeatedField(2, control.messageIDs):
    trace "decodeIHave: read messageIDs", message_ids = control.messageIDs
  else:
    trace "decodeIHave: no messageIDs"
  ok(control)

proc decodeIWant*(pb: ProtoBuffer): ProtoResult[ControlIWant] {.inline.} =
  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_read.inc(pb.getLen().int64, labelValues = ["iwant"])

  trace "decodeIWant: decoding message"
  var control = ControlIWant()
  if ? pb.getRepeatedField(1, control.messageIDs):
    trace "decodeIWant: read messageIDs", message_ids = control.messageIDs
  else:
    trace "decodeIWant: no messageIDs"
  ok(control)

proc decodeControl*(pb: ProtoBuffer): ProtoResult[Option[ControlMessage]] {.
     inline.} =
  trace "decodeControl: decoding message"
  var buffer: seq[byte]
  if ? pb.getField(3, buffer):
    var control: ControlMessage
    var cpb = initProtoBuffer(buffer)
    var ihavepbs: seq[seq[byte]]
    var iwantpbs: seq[seq[byte]]
    var graftpbs: seq[seq[byte]]
    var prunepbs: seq[seq[byte]]
    var idontwant: seq[seq[byte]]
    if ? cpb.getRepeatedField(1, ihavepbs):
      for item in ihavepbs:
        control.ihave.add(? decodeIHave(initProtoBuffer(item)))
    if ? cpb.getRepeatedField(2, iwantpbs):
      for item in iwantpbs:
        control.iwant.add(? decodeIWant(initProtoBuffer(item)))
    if ? cpb.getRepeatedField(3, graftpbs):
      for item in graftpbs:
        control.graft.add(? decodeGraft(initProtoBuffer(item)))
    if ? cpb.getRepeatedField(4, prunepbs):
      for item in prunepbs:
        control.prune.add(? decodePrune(initProtoBuffer(item)))
    if ? cpb.getRepeatedField(5, idontwant):
      for item in idontwant:
        control.idontwant.add(? decodeIWant(initProtoBuffer(item)))
    trace "decodeControl: message statistics", graft_count = len(control.graft),
                                               prune_count = len(control.prune),
                                               ihave_count = len(control.ihave),
                                               iwant_count = len(control.iwant)
    ok(some(control))
  else:
    ok(none[ControlMessage]())

proc decodeSubscription*(pb: ProtoBuffer): ProtoResult[SubOpts] {.inline.} =
  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_read.inc(pb.getLen().int64, labelValues = ["subs"])

  trace "decodeSubscription: decoding message"
  var subflag: uint64
  var sub = SubOpts()
  if ? pb.getField(1, subflag):
    sub.subscribe = bool(subflag)
    trace "decodeSubscription: read subscribe", subscribe = subflag
  else:
    trace "decodeSubscription: subscribe is missing"
  if ? pb.getField(2, sub.topic):
    trace "decodeSubscription: read topic", topic = sub.topic
  else:
    trace "decodeSubscription: topic is missing"
  ok(sub)

proc decodeSubscriptions*(pb: ProtoBuffer): ProtoResult[seq[SubOpts]] {.
     inline.} =
  trace "decodeSubscriptions: decoding message"
  var subpbs: seq[seq[byte]]
  var subs: seq[SubOpts]
  let res = ? pb.getRepeatedField(1, subpbs)
  if res:
    trace "decodeSubscriptions: read subscriptions", count = len(subpbs)
    for item in subpbs:
      subs.add(? decodeSubscription(initProtoBuffer(item)))
    if len(subs) == 0:
      trace "decodeSubscription: no subscriptions found"
  ok(subs)

proc decodeMessage*(pb: ProtoBuffer): ProtoResult[Message] {.inline.} =
  when defined(libp2p_protobuf_metrics):
    libp2p_pubsub_rpc_bytes_read.inc(pb.getLen().int64, labelValues = ["message"])

  trace "decodeMessage: decoding message"
  var msg: Message
  if ? pb.getField(1, msg.fromPeer):
    trace "decodeMessage: read fromPeer", fromPeer = msg.fromPeer
  else:
    trace "decodeMessage: fromPeer is missing"
  if ? pb.getField(2, msg.data):
    trace "decodeMessage: read data", data = msg.data.shortLog()
  else:
    trace "decodeMessage: data is missing"
  if ? pb.getField(3, msg.seqno):
    trace "decodeMessage: read seqno", seqno = msg.seqno
  else:
    trace "decodeMessage: seqno is missing"
  if ?pb.getField(4, msg.topic):
    trace "decodeMessage: read topic", topic = msg.topic
  else:
    trace "decodeMessage: topic is missing"
  if ? pb.getField(5, msg.signature):
    trace "decodeMessage: read signature", signature = msg.signature.shortLog()
  else:
    trace "decodeMessage: signature is missing"
  if ? pb.getField(6, msg.key):
    trace "decodeMessage: read public key", key = msg.key.shortLog()
  else:
    trace "decodeMessage: public key is missing"
  ok(msg)

proc decodeMessages*(pb: ProtoBuffer): ProtoResult[seq[Message]] {.inline.} =
  trace "decodeMessages: decoding message"
  var msgpbs: seq[seq[byte]]
  var msgs: seq[Message]
  if ? pb.getRepeatedField(2, msgpbs):
    trace "decodeMessages: read messages", count = len(msgpbs)
    for item in msgpbs:
      # size is constrained at the network level
      msgs.add(? decodeMessage(initProtoBuffer(item, maxSize = uint.high)))
  else:
    trace "decodeMessages: no messages found"
  ok(msgs)

proc encodeRpcMsg*(msg: RPCMsg, anonymize: bool): seq[byte] =
  trace "encodeRpcMsg: encoding message", msg = msg.shortLog()
  var pb = initProtoBuffer(maxSize = uint.high)
  for item in msg.subscriptions:
    pb.write(1, item)
  for item in msg.messages:
    pb.write(2, item, anonymize)
  msg.control.withValue(control):
    pb.write(3, control)
  # nim-libp2p extension, using fields which are unlikely to be used
  # by other extensions
  if msg.ping.len > 0:
    pb.write(60, msg.ping)
  if msg.pong.len > 0:
    pb.write(61, msg.pong)
  if len(pb.buffer) > 0:
    pb.finish()
  pb.buffer

proc decodeRpcMsg*(msg: seq[byte]): ProtoResult[RPCMsg] {.inline.} =
  trace "decodeRpcMsg: decoding message", msg = msg.shortLog()
  var pb = initProtoBuffer(msg, maxSize = uint.high)
  var rpcMsg = RPCMsg()
  assign(rpcMsg.messages, ? pb.decodeMessages())
  assign(rpcMsg.subscriptions, ? pb.decodeSubscriptions())
  assign(rpcMsg.control, ? pb.decodeControl())
  discard ? pb.getField(60, rpcMsg.ping)
  discard ? pb.getField(61, rpcMsg.pong)
  ok(rpcMsg)
