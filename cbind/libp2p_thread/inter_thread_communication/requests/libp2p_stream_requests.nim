# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/tables
import chronos, results
import ../../../[alloc, ffi_types, types]
import ../../../../libp2p
import ../../../../libp2p/crypto/curve25519
import ../../../../libp2p/crypto/secp
import ../../../../libp2p/protocols/mix
import ../../../../libp2p/protocols/mix/curve25519 as mix_curve25519
import ../../../../libp2p/protocols/mix/mix_node

type StreamMsgType* = enum
  DIAL
  MIX_DIAL
  MIX_REGISTER_DEST_READ
  MIX_SET_NODE_INFO
  MIX_NODEPOOL_ADD
  CLOSE
  CLOSE_WITH_EOF
  RELEASE
  WRITE
  WRITELP
  READEXACTLY
  READLP

type StreamRequest* = object
  operation*: StreamMsgType
  peerId: cstring
  multiaddr: cstring
  proto: cstring
  mixReadBehaviorKind: cint
  mixReadBehaviorParam: cint
  connHandle: ptr Libp2pStream
  mixPubKey: Curve25519Key32
  libp2pPubKey: Secp256k1PubKey33
  data: SharedSeq[byte] ## Only used for WRITE/WRITELP
  readLen: csize_t ## Only used for READEXACTLY
  maxSize: int64 ## Only used for READLP


proc createShared*(
    T: type StreamRequest,
    op: StreamMsgType,
    peerId: cstring = "",
    multiaddr: cstring = "",
    proto: cstring = "",
    mixReadBehaviorKind: cint = MIX_READ_EXACTLY.cint,
    mixReadBehaviorParam: cint = 0,
    conn: ptr Libp2pStream = nil,
    mixPubKey: Curve25519Key32 = default(Curve25519Key32),
    libp2pPubKey: Secp256k1PubKey33 = default(Secp256k1PubKey33),
    data: ptr byte = nil,
    dataLen: csize_t = 0,
    readLen: csize_t = 0,
    maxSize: int64 = -1,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].multiaddr = multiaddr.alloc()
  ret[].proto = proto.alloc()
  ret[].mixReadBehaviorKind = mixReadBehaviorKind
  ret[].mixReadBehaviorParam = mixReadBehaviorParam
  ret[].connHandle = conn
  ret[].mixPubKey = mixPubKey
  ret[].libp2pPubKey = libp2pPubKey
  ret[].data = allocSharedSeqFromCArray(data, dataLen.int)
  ret[].readLen = readLen
  ret[].maxSize = maxSize
  ret

proc destroyShared(self: ptr StreamRequest) =
  deallocShared(self[].peerId)
  deallocShared(self[].multiaddr)
  deallocShared(self[].proto)
  deallocSharedSeq(self[].data)
  deallocShared(self)

proc processDial*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[ptr Libp2pStream, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let peerId = PeerId.init($self[].peerId).valueOr:
    return err($error)
  let conn =
    try:
      await libp2p.switch.dial(peerId, $self[].proto)
    except DialFailedError as exc:
      return err(exc.msg)

  let handle = cast[ptr Libp2pStream](createShared(Libp2pStream, 1))
  handle[].conn = cast[pointer](conn)
  libp2p[].connections[handle] = conn

  return ok(handle)

proc processMixRegisterDestRead*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let mixProto = libp2p[].mix.valueOr:
    return err("mix protocol is not mounted")

  if self[].proto.isNil() or self[].proto[0] == '\0':
    return err("proto is empty")

  let sizeParam = self[].mixReadBehaviorParam.int
  case MixReadBehaviorKind(self[].mixReadBehaviorKind)
  of MIX_READ_EXACTLY:
    if sizeParam < 0:
      return err("readExactly size must be >= 0")
    mixProto.registerDestReadBehavior($self[].proto, readExactly(sizeParam))
  of MIX_READ_LP:
    if sizeParam < 0:
      return err("readLp max size must be >= 0")
    mixProto.registerDestReadBehavior($self[].proto, readLp(sizeParam))

  return ok("")

proc processMixDial*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[ptr Libp2pStream, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let mixProto = libp2p[].mix.valueOr:
    return err("mix protocol is not mounted")

  let peerId = PeerId.init($self[].peerId).valueOr:
    return err($error)
  let maddr = MultiAddress.init($self[].multiaddr).valueOr:
    return err($error)

  let conn = mixProto.toConnection(MixDestination.init(peerId, maddr), $self[].proto)
    .valueOr:
      return err(error)

  let handle = cast[ptr Libp2pStream](createShared(Libp2pStream, 1))
  handle[].conn = cast[pointer](conn)
  libp2p[].connections[handle] = conn

  return ok(handle)

proc processMixSetNodeInfo*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  if self[].multiaddr.isNil() or self[].multiaddr[0] == '\0':
    return err("node multiaddr is empty")

  if self[].data.len != mix_curve25519.FieldElementSize:
    return err("mix private key must be " & $mix_curve25519.FieldElementSize & " bytes")

  let mixPrivKeyBytes = self[].data.toSeq
  let mixPrivKey = bytesToFieldElement(mixPrivKeyBytes).valueOr:
    return err("mix private key is not a valid priv key")
  
  let mixPubKey = public(mixPrivKey)

  let nodeAddr = MultiAddress.init($self[].multiaddr).valueOr:
    return err($error)

  let peerInfo = libp2p[].switch.peerInfo
  if peerInfo.isNil():
    return err("switch peerInfo is nil")

  let libp2pPubKey =
    case peerInfo.publicKey.scheme
    of PKScheme.Secp256k1:
      peerInfo.publicKey.skkey
    else:
      return err("peerInfo public key must be secp256k1")

  let libp2pPrivKey =
    case peerInfo.privateKey.scheme
    of PKScheme.Secp256k1:
      peerInfo.privateKey.skkey
    else:
      return err("peerInfo private key must be secp256k1")

  libp2p[].mixNodeInfo = Opt.some(
    initMixNodeInfo(
      peerInfo.peerId,
      nodeAddr,
      mixPubKey,
      mixPrivKey,
      libp2pPubKey,
      libp2pPrivKey,
    )
  )

  if libp2p[].mix.isNone:
    var mixProto = new(MixProtocol)
    var delayStrategy = NoSamplingDelayStrategy.new(newRng())
    mixProto.init(
      libp2p[].mixNodeInfo.get(), libp2p[].switch, delayStrategy = delayStrategy
    )

    try:    
      libp2p[].switch.mount(mixProto)
    except LPError as exc:
      return err("could not mount mix: " & exc.msg)


    libp2p[].mix = Opt.some(mixProto)

  return ok("")

proc processMixNodePoolAdd*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let mixProto = libp2p[].mix.valueOr:
    return err("mix protocol is not mounted")

  if self[].peerId.isNil() or self[].peerId[0] == '\0':
    return err("peerId is empty")
  if self[].multiaddr.isNil() or self[].multiaddr[0] == '\0':
    return err("multiaddr is empty")

  let peerId = PeerId.init($self[].peerId).valueOr:
    return err($error)
  let maddr = MultiAddress.init($self[].multiaddr).valueOr:
    return err($error)

  let mixPubKey = mix_curve25519.bytesToFieldElement(self[].mixPubKey.bytes).valueOr:
    return err("mix public key invalid: " & error)

  let libp2pPubKey = SkPublicKey.init(self[].libp2pPubKey.bytes).valueOr:
    return err("libp2p public key invalid")

  mixProto.nodePool.add(MixPubInfo.init(peerId, maddr, mixPubKey, libp2pPubKey))
  return ok("")

proc processClose*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let handle = self[].connHandle
  if handle.isNil():
    return err("invalid connection handle")

  let conn = libp2p[].connections.getOrDefault(handle, nil)
  if conn.isNil():
    return err("unknown connection handle")

  case self.operation
  of CLOSE:
    await conn.close()
  of CLOSE_WITH_EOF:
    await conn.closeWithEOF()
  else:
    raiseAssert "unsupported operation"

  return ok("")

proc processRelease*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let handle = self[].connHandle
  if handle.isNil():
    return err("invalid connection handle")

  if not libp2p[].connections.hasKey(handle):
    return err("unknown connection handle")

  libp2p[].connections.del(handle)
  deallocShared(handle)

  return ok("")

proc processWrite*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let handle = self[].connHandle
  if handle.isNil():
    return err("invalid connection handle")

  let conn = libp2p[].connections.getOrDefault(handle, nil)
  if conn.isNil():
    return err("unknown connection handle")

  try:
    case self.operation
    of WRITE:
      await conn.write(self[].data.toSeq())
    of WRITELP:
      await conn.writeLp(self[].data.toSeq())
    else:
      raiseAssert "unsupported operation in processWrite"
  except LPStreamError as exc:
    return err(exc.msg)

  return ok("")

proc processRead*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[ptr ReadResponse, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let handle = self[].connHandle
  if handle.isNil():
    return err("invalid connection handle")

  let conn = libp2p[].connections.getOrDefault(handle, nil)
  if conn.isNil():
    return err("unknown connection handle")

  try:
    case self.operation
    of READEXACTLY:
      if self[].readLen > csize_t(int.high):
        return err("read length too large")
      let expected = int(self[].readLen)
      if expected == 0:
        return ok(allocReadResponse(@[]))
      var buf = newSeqUninit[byte](expected)
      await conn.readExactly(addr buf[0], expected)
      return ok(allocReadResponse(buf))
    of READLP:
      if self[].maxSize > int64(int.high) or self[].maxSize < int64(int.low):
        return err("maxSize out of range")
      let data = await conn.readLp(int(self[].maxSize))
      return ok(allocReadResponse(data))
    else:
      raiseAssert "unsupported operation in processRead"
  except LPStreamError as exc:
    return err(exc.msg)
