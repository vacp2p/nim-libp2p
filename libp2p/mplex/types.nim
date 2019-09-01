## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

const MaxMsgSize* = 1 shl 20 # 1mb

type 
  MessageType* = enum
    New, InMsg, OutMsg, InClose, OutClose, InReset, OutReset

  Message* = ref object of RootObj
    id*: int
    msgaType*: MessageType
    data*: seq[byte]
