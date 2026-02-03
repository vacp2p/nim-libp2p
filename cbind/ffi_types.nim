# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

# FFI Types and Utilities
#
# This file defines the core types and utilities for the library's foreign
# function interface (FFI), enabling interoperability with external code.

################################################################################
### Exported types

type Libp2pPrivateKey* = object
  data*: pointer

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

# These are used to indicate whether a config item has been set or not
const Libp2pCfgGossipsub* = 1'u32 shl 0
const Libp2pCfgGossipsubTriggerSelf* = 1'u32 shl 1
const Libp2pCfgKad* = 1'u32 shl 2
const Libp2pCfgDnsResolver* = 1'u32 shl 3
const Libp2pCfgKadBootstrapNodes* = 1'u32 shl 4
const Libp2pCfgPrivateKey* = 1'u32 shl 5

type Libp2pBootstrapNode* = object
  peerId*: cstring
  multiaddrs*: ptr cstring
  multiaddrsLen*: csize_t

type Libp2pConfig* = object
  flags*: uint32
  mountGossipsub*: cint
  gossipsubTriggerSelf*: cint
  mountKad*: cint
  dnsResolver*: cstring
  kadBootstrapNodes*: ptr Libp2pBootstrapNode
  kadBootstrapNodesLen*: csize_t
  passPrivKey*: cint
  privKey*: Libp2pPrivateKey

type RetCode* {.size: sizeof(cint).} = enum
  RET_OK = 0
  RET_ERR = 1
  RET_MISSING_CALLBACK = 2

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
