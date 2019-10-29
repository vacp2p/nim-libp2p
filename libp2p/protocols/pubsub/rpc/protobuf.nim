## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronicles
import messages, 
       ../../../protobuf/minprotobuf

proc encodeGraft*(graft: ControlGraft, pb: var ProtoBuffer) {.gcsafe.} = 
  pb.write(initProtoField(1, graft.topicID))

proc decodeGraft*(pb: var ProtoBuffer): seq[ControlGraft] {.gcsafe.} = 
  discard

proc encodePrune*(prune: ControlPrune, pb: var ProtoBuffer) {.gcsafe.} = 
  pb.write(initProtoField(1, prune.topicID))

proc decodePrune*(pb: var ProtoBuffer): seq[ControlPrune] {.gcsafe.} = 
  discard

proc encodeIHave*(ihave: ControlIHave, pb: var ProtoBuffer) {.gcsafe.} = 
  pb.write(initProtoField(1, ihave.topicId))
  for mid in ihave.messageIDs:
    pb.write(initProtoField(2, mid))

proc decodeIHave*(pb: var ProtoBuffer): seq[ControlIHave] {.gcsafe.} = 
  discard

proc encodeIWant*(iwant: ControlIWant, pb: var ProtoBuffer) {.gcsafe.} = 
  for mid in iwant.messageIDs:
    pb.write(initProtoField(1, mid))

proc decodeIWant*(pb: var ProtoBuffer): seq[ControlIWant] {.gcsafe.} = 
  discard

proc encodeControl*(control: ControlMessage, pb: var ProtoBuffer) {.gcsafe.} = 
  if control.ihave.len > 0:
    var ihave = initProtoBuffer()
    for h in control.ihave:
      h.encodeIHave(ihave)
    
    # write messages to protobuf
    ihave.finish()
    pb.write(initProtoField(1, ihave))

  if control.iwant.len > 0:
    var iwant = initProtoBuffer()
    for w in control.iwant:
      w.encodeIWant(iwant)
    
    # write messages to protobuf
    iwant.finish()
    pb.write(initProtoField(2, iwant))

  if control.graft.len > 0:
    var graft = initProtoBuffer()
    for g in control.graft:
      g.encodeGraft(graft)
    
    # write messages to protobuf
    graft.finish()
    pb.write(initProtoField(3, graft))

  if control.prune.len > 0:
    var prune = initProtoBuffer()
    for p in control.prune:
      p.encodePrune(prune)
    
    # write messages to protobuf
    prune.finish()
    pb.write(initProtoField(4, prune))

proc decodeControl*(pb: var ProtoBuffer): Option[ControlMessage] {.gcsafe.} = 
  discard

proc encodeSubs*(subs: SubOpts, pb: var ProtoBuffer) {.gcsafe.} = 
  pb.write(initProtoField(1, subs.subscribe))
  pb.write(initProtoField(2, subs.topic))

proc decodeSubs*(pb: var ProtoBuffer): seq[SubOpts] {.gcsafe.} = 
  while true:
    var subOpt: SubOpts
    var subscr: int
    discard pb.getVarintValue(1, subscr)
    subOpt.subscribe = cast[bool](subscr)
    trace "read subscribe field", subscribe = subOpt.subscribe

    if pb.getString(2, subOpt.topic) < 0:
      break
    trace "read subscribe field", topicName = subOpt.topic

    result.add(subOpt)

  trace "got subscriptions", subscriptions = result

proc encodeMessage*(msg: Message, pb: var ProtoBuffer) {.gcsafe.} = 
  pb.write(initProtoField(1, msg.fromPeer))
  pb.write(initProtoField(2, msg.data))
  pb.write(initProtoField(3, msg.seqno))

  for t in msg.topicIDs:
    pb.write(initProtoField(4, t))

  if msg.signature.len > 0:
    pb.write(initProtoField(5, msg.signature))
  
  if msg.key.len > 0:
    pb.write(initProtoField(6, msg.key))

  pb.finish()

proc decodeMessages*(pb: var ProtoBuffer): seq[Message] {.gcsafe.} = 
  # TODO: which of this fields are really optional?
  while true:
    var msg: Message
    if pb.getBytes(1, msg.fromPeer) < 0:
      break
    trace "read message field", fromPeer = msg.fromPeer

    if pb.getBytes(2, msg.data) < 0:
      break
    trace "read message field", data = msg.data

    if pb.getBytes(3, msg.seqno) < 0:
      break
    trace "read message field", seqno = msg.seqno

    var topic: string
    while true:
      if pb.getString(4, topic) < 0:
        break
      msg.topicIDs.add(topic)
      trace "read message field", topicName = topic
      topic = ""
    
    discard pb.getBytes(5, msg.signature)
    trace "read message field", signature = msg.signature

    discard pb.getBytes(6, msg.key)
    trace "read message field", key = msg.key

    result.add(msg)

proc encodeRpcMsg*(msg: RPCMsg): ProtoBuffer {.gcsafe.} = 
  result = initProtoBuffer()
  trace "encoding msg: ", msg = msg

  if msg.subscriptions.len > 0:
    var subs = initProtoBuffer()
    for s in msg.subscriptions:
      encodeSubs(s, subs)

    # write subscriptions to protobuf
    subs.finish()
    result.write(initProtoField(1, subs))

  if msg.messages.len > 0:
    var messages = initProtoBuffer()
    for m in msg.messages:
      encodeMessage(m, messages)

    # write messages to protobuf
    messages.finish()
    result.write(initProtoField(2, messages))

  if msg.control.isSome:
    var control = initProtoBuffer()
    msg.control.get.encodeControl(control)

    # write messages to protobuf
    control.finish()
    result.write(initProtoField(3, control))

  if result.buffer.len > 0:
    result.finish()

proc decodeRpcMsg*(msg: seq[byte]): RPCMsg {.gcsafe.} = 
  var pb = initProtoBuffer(msg)

  result.subscriptions = newSeq[SubOpts]()
  while true:
    # decode SubOpts array
    var field = pb.enterSubMessage()
    trace "processing submessage", field = field
    case field:
    of 0:
      break
    of 1:
      result.subscriptions = pb.decodeSubs()
    of 2:
      result.messages = pb.decodeMessages()
    of 3:
      result.control = pb.decodeControl()
    else: 
      raise newException(CatchableError, "message type not recognized")
