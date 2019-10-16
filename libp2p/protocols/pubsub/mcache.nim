## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables
import rpcmsg, timedcache

type
  CacheEntry* = object
    mid*: string
    topics*: seq[string]

  MCache* = ref object of RootObj
    msgs*: Table[string, RPCMsg]
    history*: seq[seq[CacheEntry]]
    gossip*: int

proc put*(c: MCache, msg: RPCMsg) = discard
proc get*(c: MCache): RPCMsg = discard
proc window*(c: MCache): seq[RPCMsg] = discard
proc shift*(c: MCache) = discard
