## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles
import ../protocol,
       ../../connection

logScope:
  topic = "floodsub"

const FloodSubCodec* = "/floodsub/1.0.0"

type
  TopicHandler* = proc(topic:string, data: seq[byte]): Future[void] {.gcsafe.}
  Topic* = object
    name*: string
    handler*: TopicHandler

  Peer* = object
    conn: Connection
    topics: string

  FloodSub* = ref object of LPProtocol
    topics: seq[Topic]
    peers: seq[Peer]

proc encodeRpcMsg() = discard
proc decodeRpcMsg() = discard

method init*(f: FloodSub) = 
  proc handler(conn: Connection, proto: string) {.async, gcsafe.} = 
    discard

  f.codec = FloodSubCodec
  f.handler = handler

method subscribe*(f: FloodSub, 
                  topic: string, 
                  handler: TopicHandler) 
                  {.base, async, gcsafe.} = 
  discard

method publish*(f: FloodSub, topic: string) {.base, async, gcsafe.} = 
  discard

proc newFloodSub*(): FloodSub = 
  new result
