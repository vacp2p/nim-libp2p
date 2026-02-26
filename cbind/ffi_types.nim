# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

# FFI Types and Utilities
#
# This file defines the core types and utilities for the library's foreign
# function interface (FFI), enabling interoperability with external code.

################################################################################
### Exported types

type Libp2pPrivateKey* {.bycopy.} = object
  data*: pointer
  dataLen*: csize_t

type Libp2pCallback* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

type Libp2pBufferCallback* = proc(
  callerRet: cint,
  data: ptr byte,
  dataLen: csize_t,
  msg: ptr cchar,
  len: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}

type Libp2pPeerInfo* = object
  peerId*: cstring
  addrs*: ptr cstring
  addrsLen*: csize_t

type PeerInfoCallback* = proc(
  callerRet: cint,
  info: ptr Libp2pPeerInfo,
  msg: ptr cchar,
  len: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}

type PeersCallback* = proc(
  callerRet: cint,
  peerIds: ptr cstring,
  peerIdsLen: csize_t,
  msg: ptr cchar,
  len: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}

type GetProvidersCallback* = proc(
  callerRet: cint,
  providers: ptr Libp2pPeerInfo,
  providersLen: csize_t,
  msg: ptr cchar,
  len: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}

type Libp2pServiceInfo* {.bycopy.} = object
  id*: cstring
  data*: ptr byte
  dataLen*: csize_t

type Libp2pKadEntryRecord* {.bycopy.} = object
  value*: ptr byte
  valueLen*: csize_t
  time*: cstring
  timeLen*: csize_t

type KadEntryValidator* = proc(
  key: ptr byte, keyLen: csize_t, record: Libp2pKadEntryRecord, userData: pointer
): cint {.cdecl, gcsafe, raises: [].}

type KadEntrySelector* = proc(
  key: ptr byte,
  keyLen: csize_t,
  records: ptr Libp2pKadEntryRecord,
  recordsLen: csize_t,
  userData: pointer,
): cint {.cdecl, gcsafe, raises: [].}

type Libp2pExtendedPeerRecord* {.bycopy.} = object
  peerId*: cstring
  seqNo*: uint64
  addrs*: ptr cstring
  addrsLen*: csize_t
  services*: ptr Libp2pServiceInfo
  servicesLen*: csize_t

type RandomRecordsCallback* = proc(
  callerRet: cint,
  records: ptr Libp2pExtendedPeerRecord,
  recordsLen: csize_t,
  msg: ptr cchar,
  len: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}

type Libp2pStream* = object
  conn*: pointer

type ConnectionCallback* = proc(
  callerRet: cint,
  conn: ptr Libp2pStream,
  msg: ptr cchar,
  len: csize_t,
  userData: pointer,
) {.cdecl, gcsafe, raises: [].}

type PubsubTopicHandler* = proc(
  topic: cstring, data: ptr byte, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

type ReadResponse* = object
  data*: ptr byte
  dataLen*: csize_t

type Libp2pBootstrapNode* = object
  peerId*: cstring
  multiaddrs*: ptr cstring
  multiaddrsLen*: csize_t

type Libp2pConfig* {.bycopy.} = object
  mountGossipsub*: cint
  gossipsubTriggerSelf*: cint
  mountKad*: cint
  mountMix*: cint
  mountKadDiscovery*: cint
  dnsResolver*: cstring
  addrs*: ptr cstring
  addrsLen*: csize_t
  kadBootstrapNodes*: ptr Libp2pBootstrapNode
  kadBootstrapNodesLen*: csize_t
  privKey*: Libp2pPrivateKey
  kadValidator*: KadEntryValidator
  kadSelector*: KadEntrySelector
  kadUserData*: pointer

type RetCode* {.size: sizeof(cint).} = enum
  RET_OK = 0
  RET_ERR = 1
  RET_MISSING_CALLBACK = 2

type MixReadBehaviorKind* {.size: sizeof(cint).} = enum
  MIX_READ_EXACTLY = 0
  MIX_READ_LP = 1

type MixCurve25519Key* {.bycopy.} = object
  bytes*: array[32, byte]

type MixSecp256k1PubKey* {.bycopy.} = object
  bytes*: array[33, byte]

### End of exported types
################################################################################

################################################################################
### FFI utils

template foreignThreadGc*(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()

type onDone* = proc()

### End of FFI utils
################################################################################
