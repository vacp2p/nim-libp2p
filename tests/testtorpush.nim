import chronos
import stew/byteutils
import libp2p
import ../libp2p/[stream/connection,
                  transports/tcptransport,
                  transports/tortransport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  builders]

import ./helpers, ./stubs/torstub, ./commontransport


## This module tests sending Torpush message over Tor as per following format
#[
    message TorPushMessage {
  optional string from = 1;
  optional bytes data = 2;
  optional bytes seqno = 3;
  required string topic = 4;
  optional bytes signature = 5;
  optional bytes key = 6;
}    
]#


type 
  Torpush* = object
    frm: string
    data: seq[byte]
    seqno: seq[byte]
    topic: string
    signature: seq[byte]
    key: seq[byte] 

{.push raises: [].}
proc encode(m: Torpush): ProtoBuffer =
  ## encodes the Torpush message into bytes
  result = initProtoBuffer()
  result.write(1, m.frm)
  result.write(2, m.data)
  result.write(3, m.seqno)
  result.write(4, m.topic)
  result.write(5, m.signature)
  result.write(6, m.key)
  result.finish()

proc decode(_: type Torpush, buf: seq[byte]): Result[Torpush, ProtoError] =
  ## decodes the bytes into Torpush message
  var res: Torpush
  let pb = initProtoBuffer(buf)  
  discard ? pb.getField(1, res.frm)
  discard ? pb.getField(2, res.data)
  discard ? pb.getField(3, res.seqno)
  discard ? pb.getField(4, res.topic)
  discard ? pb.getField(5, res.signature)
  discard ? pb.getField(6, res.key)
  ok(res) 

type
  TorpushProto = ref object of LPProtocol
 
proc new(_: typedesc[TorpushProto]): TorpushProto =
  var res: TorpushProto
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    echo "handling"
    var tp: Torpush
    tp.topic = "mytor"
    let tpbuf = tp.encode()
    await conn.writeLp(tpbuf.buffer)
    #echo Torpush.decode(await conn.readLp(1024)).value
    
    await conn.close()

  res = TorpushProto.new(@["/meshsub/1.1.0"], handle)
  return res


const torServer = initTAddress("127.0.0.1", 9050.Port)

proc main() {.async, gcsafe.} =
  let rng = newRng() 
  let
    torpushProto1 = TorpushProto.new()
    torpushProto2 = TorpushProto.new()
    torswitch1 = newStandardSwitch(rng=rng)
    switch2 = newStandardSwitch(rng=rng)
  
  #let torclient = TorTransport.new(transportAddress = torServer, upgrade = Upgrade())
  #let torswitch1 = TorSwitch.new(torServer = torServer, rng= rng, flags = {ReuseAddr})
  echo "hi"
  torswitch1.mount(torpushProto1)
  switch2.mount(torpushProto2)
  await switch2.start()
  await torswitch1.start()

  #echo torclient.transportAddress, "\n"
  #let conn = await torclient.dial("", switch2.peerInfo.addrs[0])

  let conn = await torswitch1.dial(switch2.peerInfo.peerId, switch2.peerInfo.addrs, torpushProto2.codecs)
  
  var res = Torpush.decode(await conn.readLp(1024))
  echo res.isOk
  echo res.value
  #[
  res.value.topic = "yourtor"
  let p = res.value.encode()
  await conn.writeLp(p.buffer)
  #await conn.readLp(1024)
  ]#
  await conn.close()
  await allFutures(torswitch1.stop(), switch2.stop()) # close connections and shutdown all transports

waitFor(main())
