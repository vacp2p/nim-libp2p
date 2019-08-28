## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import protobuf/minprotobuf, peerinfo, 
       switchtypes, protocol, connection,
       peer, crypto/crypto, multiaddress

const IdentifyCodec = "/ipfs/id/1.0.0"
const IdentifyPushCodec = "/ipfs/id/push/1.0.0"
const ProtoVersion = "ipfs/0.1.0"
const AgentVersion = "nim-libp2p/0.0.1"

type
  # TODO: we're doing protobuf manualy, this is only temporary
  ProtoField[T] = object
    index: int
    field: T

  IdentifyInfo = object
    peerInfo: PeerInfo
    observedAddr: MultiAddress
    protoVersion: string
    agentVersion: string

  Identify = ref object of switchtypes.Protocol

proc encodeIdentifyMsg(p: Identify, observedAddrs: Multiaddress): ProtoBuffer = 
  result = initProtoBuffer({WithVarintLength})
  var pubKey: PublicKey
  if p.peerInfo.peerId.extractPublicKey(pubkey) != true:
    raise newException(CatchableError, "unable to extract public key")

  result.write(initProtoField(1, pubKey))
  for ma in p.peerInfo.addrs:
    result.write(initProtoField(2, ma.data.buffer))

  for item in p.peerInfo.protocols:
    result.write(initProtoField(3, item))

  result.write(initProtoField(4, observedAddrs.data.buffer))

  let protoVersion = ProtoVersion
  result.write(initProtoField(5, protoVersion))

  let agentVersion = AgentVersion
  result.write(initProtoField(6, agentVersion))

  result.finish()

proc getPeerInfo(pb: var ProtoBuffer): PeerInfo =
  ## Get PeerInfo object from ``pb``.
  result.addrs = newSeq[MultiAddress]()
  if pb.getValue(1, result.peerId) == -1:
    raise newException(CatchableError, "Missing required field `publicKey`!")
  var address = newSeq[byte]()
  while pb.getBytes(2, address) != -1:
    if len(address) != 0:
      var copyaddr = address
      result.addrs.add(MultiAddress.init(copyaddr))
      address.setLen(0)

proc decodeIdentifyMsg(p: Identify, buf: seq[byte]): IdentifyInfo = 
  var pb = initProtoBuffer(buf)
  result.peerInfo = pb.getPeerInfo()

  var proto = ""
  var protos: seq[string] = newSeq[string]()
  while pb.getString(3, proto) > 0:
    protos.add(proto)
    proto = "" # TODO: do i need to clear it up?

  var observableAddr = newSeq[byte]()
  if pb.getBytes(4, observableAddr) > 0: # attempt to read the observed addr
    result.observedAddr = MultiAddress.init(observableAddr)

  result.protoVersion = ""
  if pb.getString(5, result.protoVersion) <= 0:
    raise newException(CatchableError, "Unable to read protocol version")

  var agentVersion = ""
  if pb.getString(5, agentVersion) <= 0:
    raise newException(CatchableError, "Unable to read agent version")

proc identify*(p: Identify, 
               conn: Connection, 
               observedAddres: MultiAddress): Future[IdentifyInfo] {.async.} = 
  var pb = p.encodeIdentifyMsg(observedAddres)
  let length = pb.getLen()
  await conn.write(pb.getPtr(), length)
  var message = await conn.readLp()
  if len(message) == 0:
    raise newException(CatchableError, "Incorrect or empty message received!")
  result = p.decodeIdentifyMsg(message)


method handle*(p: Identify, peerInfo: PeerInfo, handler: ProtoHandler) {.async.} = discard
